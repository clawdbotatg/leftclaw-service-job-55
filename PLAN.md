# Build Plan — Job #55

## Client
0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471

## Spec
Burn Grid — CLAWD Multiplier Grid Game. Build and deploy a BurnGrid.sol smart contract + minimal frontend on Base. A 10x10 grid of 100 cells each hides a multiplier. Players burn CLAWD to claim a cell and instantly learn its multiplier. 20% of every cell pick is permanently burned. Rounds reset automatically and run forever.

Contract: BurnGrid.sol

State: cellPrice fixed at 500000 CLAWD (500000 * 1e18 wei). gridSize fixed at 100 cells (10x10). burnPercent fixed at 20. roundId increments each round. roundEnd timestamp 48 hours after round starts. commitHash keccak256 of the round seed set by owner before round opens. claimed mapping(uint8 => address) tracks who claimed each cell index 0-99. picks mapping(address => uint8[]) tracks which cells each address picked. pot uint256 total CLAWD in prize pool this round (80% of each pick). roundSeed bytes32 revealed after round ends.

Multiplier tiers derived from seed at reveal time using keccak256(seed, cellIndex) % 1000:
- 0-499 (50 cells): 0x — nothing
- 500-799 (30 cells): 1x — get cellPrice back
- 800-919 (12 cells): 2x — get 2*cellPrice back
- 920-979 (6 cells): 3x — get 3*cellPrice back
- 980-994 (1-2 cells): 5x — get 5*cellPrice back
- 995-999 (0-1 cells): 10x — jackpot, get 10*cellPrice back
Expected payout is ~87% of pot leaving ~13% house edge for burns and rollovers.

Functions:
pickCell(uint8 cellIndex) — public. Requires round not expired and cell not yet claimed. Transfers cellPrice CLAWD from caller. Burns 20% (cellPrice * 20 / 100) to address(0) immediately. Adds remaining 80% to pot. Marks cell as claimed by caller. Emits CellPicked(roundId, cellIndex, caller).

revealRound(bytes32 seed) — callable by anyone after roundEnd OR when all 100 cells are claimed, whichever comes first. Requires keccak256(seed) == commitHash. Iterates all claimed cells, computes multiplier for each from keccak256(seed, cellIndex), pays out winners from pot. Any pot remaining after all payouts: burn 50% to address(0), carry 50% into next round pot as seed funding. Emits RoundRevealed(roundId, seed). Auto-increments roundId, resets claimed mapping, sets new roundEnd = block.timestamp + 48 hours. Owner must call setCommit before next round can accept picks.

setCommit(bytes32 hash) — owner only. Sets commitHash for the upcoming or current round. Must be called to open a fresh round after each reveal.

getCells() — view. Returns array of 100 addresses (zero address = unclaimed) showing current claimed state.
getRoundInfo() — view. Returns roundId, roundEnd, pot, claimedCount, commitHash.

Randomness: commit-reveal. Owner commits keccak256(seed) before round opens. After round ends, anyone who knows the seed (owner publishes it) calls revealRound(seed). Multipliers derived deterministically from keccak256(seed, cellIndex). Owner cannot manipulate after sales begin because seed was committed. No external oracle needed.

CLAWD token on Base: 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07. Burn to address(0).

Frontend: 10x10 grid rendered as clickable tiles. Unclaimed cells show a lobster claw icon and the cell price. Claimed cells show the claimer address truncated. After reveal, each cell animates to show its multiplier (grey=0x, green=1x, blue=2x, gold=3x, purple=5x, red=10x jackpot). Show current pot size, time remaining countdown, cells claimed count, and a pick input for cell index. Past rounds panel showing roundId, total pot, biggest winner, total burned that round. Stack: scaffold-eth 2, Next.js, wagmi/viem. Deploy frontend to Vercel.

Deploy contract to Base mainnet, verify on Basescan. Owner wallet: 0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471. No proxy. Owner calls setCommit(hash) to open first round immediately after deploy.

## Deploy
- Chain: Base (8453)
- RPC: Alchemy (ALCHEMY_API_KEY in .env)
- Deployer: 0x7a8b288AB00F5b469D45A82D4e08198F6Eec651C (DEPLOYER_PRIVATE_KEY in .env)
- All owner/admin/treasury roles transfer to client: 0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471
