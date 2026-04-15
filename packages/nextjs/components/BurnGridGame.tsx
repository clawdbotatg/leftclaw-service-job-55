"use client";

import { useEffect, useMemo, useState } from "react";
import { Address } from "@scaffold-ui/components";
import { encodePacked, erc20Abi, formatUnits, keccak256, zeroAddress } from "viem";
import { useAccount } from "wagmi";
import { useReadContract, useWriteContract } from "wagmi";
import {
  useDeployedContractInfo,
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useTargetNetwork,
} from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

const CELL_PRICE = 500_000n * 10n ** 18n;
const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

function getMultiplier(roll: number): number {
  if (roll < 500) return 0;
  if (roll < 800) return 1;
  if (roll < 920) return 2;
  if (roll < 980) return 3;
  if (roll < 995) return 5;
  return 10;
}

function computeCellMultiplier(seed: `0x${string}`, cellIndex: number): number {
  const packed = encodePacked(["bytes32", "uint8"], [seed, cellIndex]);
  const hash = keccak256(packed);
  const roll = Number(BigInt(hash) % 1000n);
  return getMultiplier(roll);
}

function formatClawd(amount: bigint): string {
  const num = Number(formatUnits(amount, 18));
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
  if (num >= 1_000) return `${Math.round(num / 1_000).toLocaleString()}K`;
  return num.toLocaleString();
}

const MULT_COLORS: Record<number, string> = {
  0: "bg-gray-500 text-gray-100",
  1: "bg-green-500 text-white",
  2: "bg-blue-500 text-white",
  3: "bg-yellow-500 text-black",
  5: "bg-purple-500 text-white",
  10: "bg-red-600 text-white",
};

export default function BurnGridGame() {
  const { address: connectedAddress } = useAccount();
  const { targetNetwork } = useTargetNetwork();

  const { data: burnGridInfo } = useDeployedContractInfo({ contractName: "BurnGrid" });
  const burnGridAddress = burnGridInfo?.address;

  // --- BurnGrid reads ---
  const { data: clawdAddress } = useScaffoldReadContract({
    contractName: "BurnGrid",
    functionName: "clawd",
  });

  const { data: roundInfo } = useScaffoldReadContract({
    contractName: "BurnGrid",
    functionName: "getRoundInfo",
  });

  const { data: cells } = useScaffoldReadContract({
    contractName: "BurnGrid",
    functionName: "getCells",
  });

  const { data: playerPicks } = useScaffoldReadContract({
    contractName: "BurnGrid",
    functionName: "getPlayerPicks",
    args: [connectedAddress ?? zeroAddress],
  });

  // --- CLAWD token reads (raw wagmi) ---
  const { data: clawdBalance, refetch: refetchBalance } = useReadContract({
    address: clawdAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [connectedAddress ?? zeroAddress],
    query: { enabled: !!clawdAddress && !!connectedAddress },
  });

  const { data: clawdAllowance, refetch: refetchAllowance } = useReadContract({
    address: clawdAddress,
    abi: erc20Abi,
    functionName: "allowance",
    args: [connectedAddress ?? zeroAddress, burnGridAddress ?? zeroAddress],
    query: { enabled: !!clawdAddress && !!connectedAddress && !!burnGridAddress },
  });

  // --- Write hooks ---
  const { writeContractAsync: pickCellAsync, isMining: isPickMining } = useScaffoldWriteContract({
    contractName: "BurnGrid",
  });

  const { writeContractAsync: approveAsync, isPending: isApproving } = useWriteContract();

  // --- Events for past rounds ---
  const { data: revealedEvents } = useScaffoldEventHistory({
    contractName: "BurnGrid",
    eventName: "RoundRevealed",
    fromBlock: 0n,
    watch: true,
  });

  const { data: pickEvents } = useScaffoldEventHistory({
    contractName: "BurnGrid",
    eventName: "CellPicked",
    fromBlock: 0n,
    watch: true,
  });

  // --- Local state ---
  const [selectedCell, setSelectedCell] = useState<number | null>(null);
  const [timeLeft, setTimeLeft] = useState("--");

  // --- Derived state ---
  const roundId = roundInfo ? Number(roundInfo[0]) : 0;
  const roundEnd = roundInfo ? Number(roundInfo[1]) : 0;
  const pot = roundInfo ? (roundInfo[2] as bigint) : 0n;
  const claimedCount = roundInfo ? Number(roundInfo[3]) : 0;
  const commitHash = roundInfo ? (roundInfo[4] as `0x${string}`) : ZERO_BYTES32;

  const isCommitSet = commitHash !== ZERO_BYTES32;
  const nowSec = Math.floor(Date.now() / 1000);
  const isRoundActive = isCommitSet && roundEnd > nowSec;
  const isRoundExpired = isCommitSet && roundEnd > 0 && roundEnd <= nowSec;
  const needsApproval = clawdAllowance !== undefined && (clawdAllowance as bigint) < CELL_PRICE;
  const hasBalance = clawdBalance !== undefined && (clawdBalance as bigint) >= CELL_PRICE;

  // --- Countdown timer ---
  useEffect(() => {
    if (!roundEnd) {
      setTimeLeft("--");
      return;
    }
    const update = () => {
      const now = Math.floor(Date.now() / 1000);
      const diff = roundEnd - now;
      if (diff <= 0) {
        setTimeLeft("Ended");
        return;
      }
      const h = Math.floor(diff / 3600);
      const m = Math.floor((diff % 3600) / 60);
      const s = diff % 60;
      setTimeLeft(`${h}h ${m}m ${s}s`);
    };
    update();
    const id = setInterval(update, 1000);
    return () => clearInterval(id);
  }, [roundEnd]);

  // --- Past rounds computation ---
  const pastRounds = useMemo(() => {
    if (!revealedEvents?.length) return [];

    return [...revealedEvents]
      .map((event: any) => {
        const rid = Number(event.args.roundId);
        const seed = event.args.seed as `0x${string}`;

        // Count picks in this round
        const roundPickEvents = pickEvents?.filter((p: any) => Number(p.args.roundId) === rid) ?? [];
        const cellsClaimed = roundPickEvents.length;
        const potEstimate = BigInt(cellsClaimed) * ((CELL_PRICE * 80n) / 100n);

        // Find biggest winner
        let biggestWinner: `0x${string}` = zeroAddress;
        let biggestPayout = 0n;
        for (const pe of roundPickEvents) {
          const ci = Number(pe.args.cellIndex);
          const mult = computeCellMultiplier(seed, ci);
          const payout = BigInt(mult) * CELL_PRICE;
          if (payout > biggestPayout) {
            biggestPayout = payout;
            biggestWinner = pe.args.player as `0x${string}`;
          }
        }

        const totalBurned = BigInt(cellsClaimed) * ((CELL_PRICE * 20n) / 100n);

        return { roundId: rid, seed, cellsClaimed, potEstimate, biggestWinner, biggestPayout, totalBurned };
      })
      .sort((a, b) => b.roundId - a.roundId);
  }, [revealedEvents, pickEvents]);

  // --- Handlers ---
  const handleApprove = async () => {
    if (!clawdAddress || !burnGridAddress) return;
    try {
      await approveAsync({
        address: clawdAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [burnGridAddress, CELL_PRICE * 200n],
      });
      notification.success("CLAWD approved!");
      refetchAllowance();
    } catch (e: any) {
      notification.error(e?.shortMessage || "Approve failed");
    }
  };

  const handlePick = async () => {
    if (selectedCell === null) return;
    try {
      await pickCellAsync({
        functionName: "pickCell",
        args: [selectedCell],
      });
      notification.success(`Cell #${selectedCell} claimed!`);
      setSelectedCell(null);
      refetchBalance();
      refetchAllowance();
    } catch (e: any) {
      notification.error(e?.shortMessage || "Pick failed");
    }
  };

  // --- Loading state ---
  if (!burnGridAddress) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4">
        <span className="loading loading-spinner loading-lg"></span>
        <p className="text-lg opacity-70">Loading BurnGrid contract...</p>
      </div>
    );
  }

  const picksArray = playerPicks as number[] | undefined;

  return (
    <div className="flex flex-col items-center gap-8 px-4 py-8">
      {/* Title */}
      <div className="text-center">
        <h1 className="text-5xl font-extrabold tracking-tight">BURN GRID</h1>
        <p className="text-lg opacity-60 mt-1">Burn CLAWD. Reveal your fate.</p>
      </div>

      {/* Round stats */}
      <div className="stats stats-vertical sm:stats-horizontal shadow bg-base-200 w-full max-w-3xl">
        <div className="stat place-items-center">
          <div className="stat-title">Round</div>
          <div className="stat-value text-primary">#{roundId}</div>
        </div>
        <div className="stat place-items-center">
          <div className="stat-title">Time Left</div>
          <div className={`stat-value ${timeLeft === "Ended" ? "text-error" : "text-secondary"}`}>{timeLeft}</div>
        </div>
        <div className="stat place-items-center">
          <div className="stat-title">Pot</div>
          <div className="stat-value text-lg">{formatClawd(pot)}</div>
          <div className="stat-desc">CLAWD</div>
        </div>
        <div className="stat place-items-center">
          <div className="stat-title">Claimed</div>
          <div className="stat-value">
            {claimedCount}
            <span className="text-base font-normal opacity-60">/100</span>
          </div>
        </div>
      </div>

      {/* Status banners */}
      {!isRoundActive && !isRoundExpired && roundId > 0 && (
        <div className="alert alert-warning w-full max-w-3xl">
          <span>Waiting for the round to open (owner must set commit hash).</span>
        </div>
      )}
      {isRoundExpired && (
        <div className="alert alert-info w-full max-w-3xl">
          <span>Round ended! Waiting for seed reveal...</span>
        </div>
      )}

      {/* Grid */}
      <div className="grid grid-cols-10 gap-1 w-full max-w-xl">
        {Array.from({ length: 100 }, (_, i) => {
          const claimer = cells ? (cells[i] as `0x${string}`) : zeroAddress;
          const isEmpty = !cells || claimer === zeroAddress;
          const isSelected = selectedCell === i;
          const isMyPick = picksArray?.includes(i) ?? false;

          return (
            <button
              key={i}
              className={`
                aspect-square flex flex-col items-center justify-center rounded-md border transition-all
                ${
                  isEmpty
                    ? isSelected
                      ? "border-primary bg-primary/30 ring-2 ring-primary scale-105"
                      : isRoundActive
                        ? "border-base-300 hover:border-primary hover:bg-primary/10 cursor-pointer"
                        : "border-base-300 opacity-50 cursor-not-allowed"
                    : isMyPick
                      ? "border-accent bg-accent/20 cursor-default"
                      : "border-base-300 bg-base-200 cursor-default"
                }
              `}
              onClick={() => {
                if (isEmpty && isRoundActive) setSelectedCell(i);
              }}
              disabled={!isEmpty || !isRoundActive}
              title={isEmpty ? `Cell #${i} — 500K CLAWD` : `Cell #${i} — claimed`}
            >
              {isEmpty ? (
                <span className="text-lg leading-none select-none">🦞</span>
              ) : (
                <span className="font-mono text-[8px] sm:text-[9px] leading-tight opacity-80">
                  {claimer.slice(0, 4)}
                  <br />
                  ..{claimer.slice(-3)}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* Multiplier legend */}
      <div className="flex flex-wrap gap-2 justify-center">
        {[
          { m: 0, l: "0x Nothing" },
          { m: 1, l: "1x Return" },
          { m: 2, l: "2x Double" },
          { m: 3, l: "3x Triple" },
          { m: 5, l: "5x Mega" },
          { m: 10, l: "10x Jackpot" },
        ].map(({ m, l }) => (
          <span key={m} className={`badge badge-sm ${MULT_COLORS[m]}`}>
            {l}
          </span>
        ))}
      </div>

      {/* Action panel */}
      {connectedAddress ? (
        <div className="card bg-base-200 shadow-lg w-full max-w-3xl">
          <div className="card-body p-4 sm:p-6">
            <div className="flex flex-wrap items-center gap-4 justify-between">
              <div className="flex gap-6">
                <div>
                  <p className="text-xs opacity-60 uppercase tracking-wide">Your CLAWD</p>
                  <p className="text-xl font-bold">
                    {clawdBalance !== undefined ? formatClawd(clawdBalance as bigint) : "--"}
                  </p>
                </div>
                <div>
                  <p className="text-xs opacity-60 uppercase tracking-wide">Selected Cell</p>
                  <p className="text-xl font-bold">{selectedCell !== null ? `#${selectedCell}` : "None"}</p>
                </div>
              </div>

              <div className="flex gap-2 items-center">
                {needsApproval && (
                  <button className="btn btn-secondary btn-sm" onClick={handleApprove} disabled={isApproving}>
                    {isApproving ? <span className="loading loading-spinner loading-xs"></span> : "Approve CLAWD"}
                  </button>
                )}
                <button
                  className="btn btn-primary"
                  onClick={handlePick}
                  disabled={selectedCell === null || isPickMining || needsApproval || !hasBalance || !isRoundActive}
                >
                  {isPickMining ? <span className="loading loading-spinner loading-sm"></span> : "Pick Cell"}
                </button>
              </div>
            </div>

            {selectedCell !== null && !hasBalance && (
              <p className="text-error text-sm mt-2">Insufficient CLAWD balance (need 500,000 CLAWD per cell).</p>
            )}
            {!isRoundActive && selectedCell !== null && (
              <p className="text-warning text-sm mt-2">Round is not active. Cannot pick cells right now.</p>
            )}
          </div>
        </div>
      ) : (
        <div className="alert w-full max-w-3xl">
          <span>Connect your wallet to play.</span>
        </div>
      )}

      {/* Past Rounds */}
      <div className="w-full max-w-3xl">
        <h2 className="text-2xl font-bold mb-4">Past Rounds</h2>
        {pastRounds.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="table table-sm">
              <thead>
                <tr>
                  <th>Round</th>
                  <th>Cells</th>
                  <th>Pot</th>
                  <th>Biggest Winner</th>
                  <th>Burned</th>
                </tr>
              </thead>
              <tbody>
                {pastRounds.map(r => (
                  <tr key={r.roundId}>
                    <td className="font-bold">#{r.roundId}</td>
                    <td>{r.cellsClaimed}/100</td>
                    <td>{formatClawd(r.potEstimate)} CLAWD</td>
                    <td>
                      {r.biggestWinner !== zeroAddress ? (
                        <div className="flex items-center gap-1">
                          <Address address={r.biggestWinner} chain={targetNetwork} size="xs" />
                          <span className="badge badge-xs badge-success">{formatClawd(r.biggestPayout)}</span>
                        </div>
                      ) : (
                        <span className="opacity-50">--</span>
                      )}
                    </td>
                    <td>{formatClawd(r.totalBurned)} CLAWD</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="text-center opacity-50 py-8">No past rounds yet.</p>
        )}
      </div>
    </div>
  );
}
