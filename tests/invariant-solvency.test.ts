import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const treasury = accounts.get("wallet_1")!;
const alice = accounts.get("wallet_2")!;
const bob = accounts.get("wallet_3")!;
const charlie = accounts.get("wallet_4")!;

describe("Obelisk Protocol Invariant, Solvency & Security Test Suite", () => {
  beforeEach(() => {
    const vaultPrincipal = `${deployer}.obelisk-vault`;
    simnet.callPublicFn("principal-token", "set-authorized-vault", [Cl.principal(vaultPrincipal)], deployer);
    simnet.callPublicFn("yield-token", "set-authorized-vault", [Cl.principal(vaultPrincipal)], deployer);
    simnet.callPublicFn("obelisk-vault", "set-treasury", [Cl.principal(treasury)], deployer);
  });

  it("invariant: multi-user deposits and proportionate yield distribution have zero balance leakage", () => {
    const startBlock = simnet.blockHeight;
    const maturityBlock = simnet.blockHeight + 200;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    // Alice deposits 30 STX (30,000,000 uSTX) -> 75% of pool
    simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(30000000n)], alice);
    // Bob deposits 10 STX (10,000,000 uSTX) -> 25% of pool
    simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(10000000n)], bob);

    // Total principal in epoch is 40,000,000 uSTX
    const epochInfo = simnet.callReadOnlyFn("obelisk-vault", "get-epoch", [Cl.uint(1)], deployer);
    expect(epochInfo.result).toBeSome(
      Cl.tuple({
        "start-block": Cl.uint(startBlock + 1),
        "maturity-block": Cl.uint(maturityBlock),
        "total-principal-stx": Cl.uint(40000000n),
        "acc-yield-per-share": Cl.uint(0),
        "total-yield-harvested": Cl.uint(0),
        "total-yield-claimed": Cl.uint(0),
        "is-finalized": Cl.bool(false),
      })
    );

    // Harvest 4,000,000 uSTX (4 STX) yield
    // 2% fee = 80,000 uSTX, net yield = 3,920,000 uSTX
    simnet.callPublicFn("obelisk-vault", "harvest-yield", [Cl.uint(1), Cl.uint(4000000n)], deployer);

    // Alice should be entitled to 75% of 3,920,000 = 2,940,000 uSTX
    const aliceYield = simnet.callReadOnlyFn("obelisk-vault", "get-pending-yield", [Cl.uint(1), Cl.principal(alice)], deployer);
    expect(aliceYield.result).toBeOk(Cl.uint(2940000n));

    // Bob should be entitled to 25% of 3,920,000 = 980,000 uSTX
    const bobYield = simnet.callReadOnlyFn("obelisk-vault", "get-pending-yield", [Cl.uint(1), Cl.principal(bob)], deployer);
    expect(bobYield.result).toBeOk(Cl.uint(980000n));

    // Alice and Bob claim their respective shares
    const aliceClaim = simnet.callPublicFn("obelisk-vault", "claim-yield", [Cl.uint(1)], alice);
    expect(aliceClaim.result).toBeOk(Cl.uint(2940000n));

    const bobClaim = simnet.callPublicFn("obelisk-vault", "claim-yield", [Cl.uint(1)], bob);
    expect(bobClaim.result).toBeOk(Cl.uint(980000n));

    // Exact conservation: 2,940,000 + 980,000 = 3,920,000 uSTX claimed
    const summary = simnet.callReadOnlyFn("obelisk-vault", "get-vault-summary", [], deployer);
    expect(summary.result).toBeOk(
      Cl.tuple({
        "total-stx-locked": Cl.uint(40000000n),
        "total-fees-collected": Cl.uint(80000n), // 2% of 4M
        "epoch-count": Cl.uint(1),
        "is-paused": Cl.bool(false),
        "protocol-fee-bps": Cl.uint(200),
        "early-exit-fee-bps": Cl.uint(50),
      })
    );
  });

  it("invariant: slippage control rejects predatory or front-run swap orders", () => {
    // Authorize deployer to mint PT to seed AMM
    simnet.callPublicFn("principal-token", "set-authorized-vault", [Cl.principal(deployer)], deployer);

    const maturityBlock = simnet.blockHeight + 500;
    simnet.callPublicFn("yield-space-amm", "initialize-pool", [Cl.uint(1), Cl.uint(maturityBlock), Cl.uint(500)], deployer);

    // Seed pool
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(deployer), Cl.uint(10000000n)], deployer);
    simnet.callPublicFn("yield-space-amm", "add-liquidity", [Cl.uint(1), Cl.uint(10000000n), Cl.uint(10000000n)], deployer);

    // Alice attempts to swap 1,000,000 STX demanding an impossible 2,000,000 PT (unrealistic slippage)
    const predatorySwap = simnet.callPublicFn(
      "yield-space-amm",
      "swap-stx-for-pt",
      [Cl.uint(1), Cl.uint(1000000n), Cl.uint(2000000n)],
      alice
    );
    expect(predatorySwap.result).toBeErr(Cl.uint(606)); // ERR_SLIPPAGE_EXCEEDED
  });

  it("invariant: zero-amount parameter guards prevent null state mutations", () => {
    const maturityBlock = simnet.blockHeight + 100;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    // Zero deposit rejected
    const zeroDeposit = simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(0)], alice);
    expect(zeroDeposit.result).toBeErr(Cl.uint(505)); // ERR_ZERO_AMOUNT

    // Zero harvest rejected
    const zeroHarvest = simnet.callPublicFn("obelisk-vault", "harvest-yield", [Cl.uint(1), Cl.uint(0)], deployer);
    expect(zeroHarvest.result).toBeErr(Cl.uint(505)); // ERR_ZERO_AMOUNT
  });

  it("invariant: non-admin callers cannot manipulate protocol fees or ownership", () => {
    // Charlie tries to raise protocol fee to 100%
    const rogueFee = simnet.callPublicFn("obelisk-vault", "set-protocol-fee", [Cl.uint(10000)], charlie);
    expect(rogueFee.result).toBeErr(Cl.uint(500)); // ERR_NOT_AUTHORIZED

    // Charlie tries to seize contract ownership
    const rogueOwner = simnet.callPublicFn("obelisk-vault", "set-contract-owner", [Cl.principal(charlie)], charlie);
    expect(rogueOwner.result).toBeErr(Cl.uint(500)); // ERR_NOT_AUTHORIZED
  });
});
