// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import { BurnGrid } from "../contracts/BurnGrid.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock CLAWD token that allows transfers to address(0) for burning.
contract MockCLAWD is ERC20 {
    constructor() ERC20("CLAWD", "CLAWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Override transfer/transferFrom to route address(0) to _burn
    function transfer(address to, uint256 value) public override returns (bool) {
        if (to == address(0)) {
            _burn(_msgSender(), value);
            return true;
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        if (to == address(0)) {
            _burn(from, value);
            return true;
        }
        _transfer(from, to, value);
        return true;
    }
}

contract BurnGridTest is Test {
    BurnGrid public grid;
    MockCLAWD public token;

    address owner = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant CELL_PRICE = 500_000 * 1e18;
    bytes32 constant SEED = keccak256("test-seed-123");
    bytes32 constant COMMIT = keccak256(abi.encodePacked(SEED));

    function setUp() public {
        token = new MockCLAWD();
        grid = new BurnGrid(address(token), owner);

        // Mint tokens to players
        token.mint(alice, CELL_PRICE * 200);
        token.mint(bob, CELL_PRICE * 200);

        // Approve grid contract
        vm.prank(alice);
        token.approve(address(grid), type(uint256).max);
        vm.prank(bob);
        token.approve(address(grid), type(uint256).max);

        // Owner sets commit to open round 1
        vm.prank(owner);
        grid.setCommit(COMMIT);
    }

    function test_initialState() public view {
        (uint256 roundId, uint256 roundEnd, uint256 pot, uint8 claimedCount, bytes32 commit) = grid.getRoundInfo();
        assertEq(roundId, 1);
        assertGt(roundEnd, block.timestamp);
        assertEq(pot, 0);
        assertEq(claimedCount, 0);
        assertEq(commit, COMMIT);
    }

    function test_pickCell() public {
        vm.prank(alice);
        grid.pickCell(0);

        (,, uint256 pot, uint8 claimedCount,) = grid.getRoundInfo();
        uint256 expectedPot = (CELL_PRICE * 80) / 100;
        assertEq(pot, expectedPot);
        assertEq(claimedCount, 1);

        address[100] memory cells = grid.getCells();
        assertEq(cells[0], alice);
    }

    function test_pickCell_burns20Percent() public {
        uint256 gridBalanceBefore = token.balanceOf(address(grid));
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        grid.pickCell(5);

        uint256 gridBalanceAfter = token.balanceOf(address(grid));
        uint256 aliceAfter = token.balanceOf(alice);

        // Alice spent CELL_PRICE
        assertEq(aliceBefore - aliceAfter, CELL_PRICE);
        // Grid received 80% (20% burned to address(0))
        assertEq(gridBalanceAfter - gridBalanceBefore, (CELL_PRICE * 80) / 100);
    }

    function test_pickCell_revertIfCellTaken() public {
        vm.prank(alice);
        grid.pickCell(0);

        vm.prank(bob);
        vm.expectRevert("Cell taken");
        grid.pickCell(0);
    }

    function test_pickCell_revertIfInvalidCell() public {
        vm.prank(alice);
        vm.expectRevert("Invalid cell");
        grid.pickCell(100);
    }

    function test_pickCell_revertIfRoundExpired() public {
        vm.warp(block.timestamp + 49 hours);

        vm.prank(alice);
        vm.expectRevert("Round expired");
        grid.pickCell(0);
    }

    function test_pickCell_revertIfNoCommit() public {
        // Deploy fresh grid without commit
        BurnGrid freshGrid = new BurnGrid(address(token), owner);

        vm.prank(alice);
        vm.expectRevert("Round not open");
        freshGrid.pickCell(0);
    }

    function test_pickCell_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit BurnGrid.CellPicked(1, 0, alice);
        grid.pickCell(0);
    }

    function test_getPlayerPicks() public {
        vm.startPrank(alice);
        grid.pickCell(0);
        grid.pickCell(5);
        grid.pickCell(99);
        vm.stopPrank();

        uint8[] memory picks = grid.getPlayerPicks(alice);
        assertEq(picks.length, 3);
        assertEq(picks[0], 0);
        assertEq(picks[1], 5);
        assertEq(picks[2], 99);
    }

    function test_setCommit_revertIfAlreadySet() public {
        // Commit is already set in setUp
        vm.prank(owner);
        vm.expectRevert("Commit already set");
        grid.setCommit(bytes32(uint256(2)));
    }

    function test_setCommit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        grid.setCommit(bytes32(uint256(1)));
    }

    function test_setCommit_startsTimer() public {
        BurnGrid freshGrid = new BurnGrid(address(token), owner);
        (, uint256 roundEnd,,,) = freshGrid.getRoundInfo();
        assertEq(roundEnd, 0);

        vm.prank(owner);
        freshGrid.setCommit(COMMIT);

        (, roundEnd,,,) = freshGrid.getRoundInfo();
        assertEq(roundEnd, block.timestamp + 48 hours);
    }

    function test_revealRound_afterTimeout() public {
        // Alice picks cell 0
        vm.prank(alice);
        grid.pickCell(0);

        // Warp past round end
        vm.warp(block.timestamp + 49 hours);

        // Anyone can reveal
        grid.revealRound(SEED);

        // Round incremented
        (uint256 roundId,,,,) = grid.getRoundInfo();
        assertEq(roundId, 2);
        assertEq(grid.roundSeed(), SEED);
    }

    function test_revealRound_allCellsClaimed() public {
        // Mint enough for 100 cells split between alice and bob
        token.mint(alice, CELL_PRICE * 100);
        token.mint(bob, CELL_PRICE * 100);

        // Claim all 100 cells
        for (uint8 i = 0; i < 50; i++) {
            vm.prank(alice);
            grid.pickCell(i);
        }
        for (uint8 i = 50; i < 100; i++) {
            vm.prank(bob);
            grid.pickCell(i);
        }

        (,,, uint8 claimedCount,) = grid.getRoundInfo();
        assertEq(claimedCount, 100);

        // Can reveal immediately (all cells claimed)
        grid.revealRound(SEED);

        (uint256 roundId,,,,) = grid.getRoundInfo();
        assertEq(roundId, 2);
    }

    function test_revealRound_revertIfNotEnded() public {
        vm.prank(alice);
        grid.pickCell(0);

        vm.expectRevert("Round not ended");
        grid.revealRound(SEED);
    }

    function test_revealRound_revertIfBadSeed() public {
        vm.prank(alice);
        grid.pickCell(0);

        vm.warp(block.timestamp + 49 hours);

        vm.expectRevert("Invalid seed");
        grid.revealRound(keccak256("wrong-seed"));
    }

    function test_revealRound_revertIfNotStarted() public {
        BurnGrid freshGrid = new BurnGrid(address(token), owner);

        vm.expectRevert("Round not started");
        freshGrid.revealRound(SEED);
    }

    function test_revealRound_paysWinners() public {
        // Pick a few cells
        vm.prank(alice);
        grid.pickCell(0);
        vm.prank(bob);
        grid.pickCell(1);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.warp(block.timestamp + 49 hours);
        grid.revealRound(SEED);

        // Check that at least one player got some tokens back (depends on seed)
        uint256 aliceAfter = token.balanceOf(alice);
        uint256 bobAfter = token.balanceOf(bob);

        // Compute expected multipliers for verification
        uint256 roll0 = uint256(keccak256(abi.encodePacked(SEED, uint8(0)))) % 1000;
        uint256 roll1 = uint256(keccak256(abi.encodePacked(SEED, uint8(1)))) % 1000;

        uint256 mult0 = _getMultiplier(roll0);
        uint256 mult1 = _getMultiplier(roll1);

        assertEq(aliceAfter - aliceBefore, mult0 * CELL_PRICE);
        assertEq(bobAfter - bobBefore, mult1 * CELL_PRICE);
    }

    function test_revealRound_burnsAndCarries() public {
        vm.prank(alice);
        grid.pickCell(0);

        uint256 potBefore = (CELL_PRICE * 80) / 100;

        vm.warp(block.timestamp + 49 hours);
        grid.revealRound(SEED);

        // Compute payout for cell 0
        uint256 roll0 = uint256(keccak256(abi.encodePacked(SEED, uint8(0)))) % 1000;
        uint256 mult0 = _getMultiplier(roll0);
        uint256 payout = mult0 * CELL_PRICE;
        if (payout > potBefore) payout = potBefore;

        uint256 leftover = potBefore - payout;
        uint256 expectedCarry = leftover - (leftover / 2);

        (,, uint256 newPot,,) = grid.getRoundInfo();
        assertEq(newPot, expectedCarry);
    }

    function test_revealRound_resetsState() public {
        vm.prank(alice);
        grid.pickCell(0);

        vm.warp(block.timestamp + 49 hours);
        grid.revealRound(SEED);

        (uint256 roundId,,, uint8 claimedCount, bytes32 commit) = grid.getRoundInfo();
        assertEq(roundId, 2);
        assertEq(claimedCount, 0);
        assertEq(commit, bytes32(0));

        // getCells should return empty for new round
        address[100] memory cells = grid.getCells();
        for (uint8 i = 0; i < 100; i++) {
            assertEq(cells[i], address(0));
        }
    }

    function test_revealRound_emitsEvent() public {
        vm.prank(alice);
        grid.pickCell(0);

        vm.warp(block.timestamp + 49 hours);

        vm.expectEmit(true, false, false, true);
        emit BurnGrid.RoundRevealed(1, SEED);
        grid.revealRound(SEED);
    }

    function test_fullRoundCycle() public {
        // Round 1: Alice picks cell 0
        vm.prank(alice);
        grid.pickCell(0);

        vm.warp(block.timestamp + 49 hours);
        grid.revealRound(SEED);

        // Round 2: Owner sets new commit
        bytes32 seed2 = keccak256("seed-round-2");
        bytes32 commit2 = keccak256(abi.encodePacked(seed2));

        vm.prank(owner);
        grid.setCommit(commit2);

        // Bob picks in round 2
        vm.prank(bob);
        grid.pickCell(42);

        vm.warp(block.timestamp + 49 hours);
        grid.revealRound(seed2);

        (uint256 roundId,,,,) = grid.getRoundInfo();
        assertEq(roundId, 3);
    }

    function test_multiplierDistribution() public pure {
        // Verify the multiplier logic matches the spec
        assertEq(_getMultiplier(0), 0);
        assertEq(_getMultiplier(499), 0);
        assertEq(_getMultiplier(500), 1);
        assertEq(_getMultiplier(799), 1);
        assertEq(_getMultiplier(800), 2);
        assertEq(_getMultiplier(919), 2);
        assertEq(_getMultiplier(920), 3);
        assertEq(_getMultiplier(979), 3);
        assertEq(_getMultiplier(980), 5);
        assertEq(_getMultiplier(994), 5);
        assertEq(_getMultiplier(995), 10);
        assertEq(_getMultiplier(999), 10);
    }

    // Mirror of contract's internal _getMultiplier for test verification
    function _getMultiplier(uint256 roll) internal pure returns (uint256) {
        if (roll < 500) return 0;
        if (roll < 800) return 1;
        if (roll < 920) return 2;
        if (roll < 980) return 3;
        if (roll < 995) return 5;
        return 10;
    }
}
