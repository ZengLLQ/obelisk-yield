import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const treasury = accounts.get("wallet_1")!;
const depositor1 = accounts.get("wallet_2")!;
const depositor2 = accounts.get("wallet_3")!;

describe("ObeliskVault Contract Test Suite", () => {
  beforeEach(() => {
    // Authorize obelisk-vault in principal-token and yield-token contracts
    const vaultPrincipal = `${deployer}.obelisk-vault`;

    simnet.callPublicFn(
      "principal-token",
      "set-authorized-vault",
      [Cl.principal(vaultPrincipal)],
      deployer
    );

    simnet.callPublicFn(
      "yield-token",
      "set-authorized-vault",
      [Cl.principal(vaultPrincipal)],
      deployer
    );

    // Set treasury address in vault
    simnet.callPublicFn(
      "obelisk-vault",
      "set-treasury",
      [Cl.principal(treasury)],
      deployer
    );
  });

  it("creates a new yield epoch with future maturity block", () => {
    const maturityBlock = simnet.blockHeight + 100;
    const createRes = simnet.callPublicFn(
      "obelisk-vault",
      "create-epoch",
      [Cl.uint(maturityBlock)],
      deployer
    );
    expect(createRes.result).toBeOk(Cl.uint(1));

    const epochInfo = simnet.callReadOnlyFn("obelisk-vault", "get-epoch", [Cl.uint(1)], deployer);
    expect(epochInfo.result).toBeSome(
      Cl.tuple({
        "start-block": Cl.uint(simnet.blockHeight),
        "maturity-block": Cl.uint(maturityBlock),
        "total-principal-stx": Cl.uint(0),
        "acc-yield-per-share": Cl.uint(0),
        "total-yield-harvested": Cl.uint(0),
        "total-yield-claimed": Cl.uint(0),
        "is-finalized": Cl.bool(false),
      })
    );
  });

  it("deposits STX into active epoch and mints 1:1 PT and YT tokens", () => {
    const maturityBlock = simnet.blockHeight + 100;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    const depositAmount = 10000000n; // 10 STX
    const depositRes = simnet.callPublicFn(
      "obelisk-vault",
      "deposit-stx",
      [Cl.uint(1), Cl.uint(depositAmount)],
      depositor1
    );
    expect(depositRes.result).toBeOk(Cl.bool(true));

    // Verify depositor received equal amounts of PT and YT
    const ptBalance = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(depositor1)], deployer);
    expect(ptBalance.result).toBeOk(Cl.uint(depositAmount));

    const ytBalance = simnet.callReadOnlyFn("yield-token", "get-balance", [Cl.principal(depositor1)], deployer);
    expect(ytBalance.result).toBeOk(Cl.uint(depositAmount));

    // Verify vault summary
    const summary = simnet.callReadOnlyFn("obelisk-vault", "get-vault-summary", [], deployer);
    expect(summary.result).toBeOk(
      Cl.tuple({
        "total-stx-locked": Cl.uint(depositAmount),
        "total-fees-collected": Cl.uint(0),
        "epoch-count": Cl.uint(1),
        "is-paused": Cl.bool(false),
        "protocol-fee-bps": Cl.uint(200),
        "early-exit-fee-bps": Cl.uint(50),
      })
    );
  });

  it("harvests yield and enables accurate streaming yield claims", () => {
    const maturityBlock = simnet.blockHeight + 100;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    const depositAmount = 10000000n; // 10 STX
    simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(depositAmount)], depositor1);

    // Harvest 1,000,000 uSTX (1 STX) yield
    const harvestAmount = 1000000n;
    const harvestRes = simnet.callPublicFn(
      "obelisk-vault",
      "harvest-yield",
      [Cl.uint(1), Cl.uint(harvestAmount)],
      deployer
    );
    // 2% fee = 20,000 uSTX, net yield = 980,000 uSTX
    expect(harvestRes.result).toBeOk(Cl.uint(980000n));

    // Check pending yield for depositor1
    const pendingYield = simnet.callReadOnlyFn(
      "obelisk-vault",
      "get-pending-yield",
      [Cl.uint(1), Cl.principal(depositor1)],
      deployer
    );
    expect(pendingYield.result).toBeOk(Cl.uint(980000n));

    // Depositor1 claims yield
    const claimRes = simnet.callPublicFn("obelisk-vault", "claim-yield", [Cl.uint(1)], depositor1);
    expect(claimRes.result).toBeOk(Cl.uint(980000n));

    // Subsequent claim immediately should fail with nothing to claim
    const claimAgain = simnet.callPublicFn("obelisk-vault", "claim-yield", [Cl.uint(1)], depositor1);
    expect(claimAgain.result).toBeErr(Cl.uint(508)); // ERR_NOTHING_TO_CLAIM
  });

  it("allows early unwind of position before maturity with small penalty fee", () => {
    const maturityBlock = simnet.blockHeight + 100;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    const depositAmount = 6000000n; // 6 STX
    simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(depositAmount)], depositor2);

    // Unwind 2,000,000 uSTX early
    const unwindAmount = 2000000n;
    const unwindRes = simnet.callPublicFn(
      "obelisk-vault",
      "early-unwind",
      [Cl.uint(1), Cl.uint(unwindAmount)],
      depositor2
    );
    // 0.5% fee = 10,000 uSTX, net refund = 1,990,000 uSTX
    expect(unwindRes.result).toBeOk(Cl.uint(1990000n));

    // PT and YT balances reduced by 2,000,000
    const ptBal = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(depositor2)], deployer);
    expect(ptBal.result).toBeOk(Cl.uint(4000000n));
  });

  it("prevents principal redemption before maturity and permits full 1:1 redemption post-maturity", () => {
    const maturityBlock = simnet.blockHeight + 50;
    simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);

    const depositAmount = 5000000n; // 5 STX
    simnet.callPublicFn("obelisk-vault", "deposit-stx", [Cl.uint(1), Cl.uint(depositAmount)], depositor1);

    // Attempt redemption before maturity -> rejects
    const earlyRedeem = simnet.callPublicFn(
      "obelisk-vault",
      "redeem-principal",
      [Cl.uint(1), Cl.uint(depositAmount)],
      depositor1
    );
    expect(earlyRedeem.result).toBeErr(Cl.uint(503)); // ERR_EPOCH_NOT_MATURED

    // Advance blocks past maturity block
    simnet.mineEmptyBlocks(60);

    // Post-maturity redemption succeeds 1:1
    const matureRedeem = simnet.callPublicFn(
      "obelisk-vault",
      "redeem-principal",
      [Cl.uint(1), Cl.uint(depositAmount)],
      depositor1
    );
    expect(matureRedeem.result).toBeOk(Cl.uint(depositAmount));

    // PT balance is now 0
    const ptBal = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(depositor1)], deployer);
    expect(ptBal.result).toBeOk(Cl.uint(0n));
  });

  it("enforces emergency pause controls", () => {
    // Pause vault
    const pauseRes = simnet.callPublicFn("obelisk-vault", "set-paused", [Cl.bool(true)], deployer);
    expect(pauseRes.result).toBeOk(Cl.bool(true));

    // Operations fail while paused
    const maturityBlock = simnet.blockHeight + 100;
    const createRes = simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);
    expect(createRes.result).toBeErr(Cl.uint(501)); // ERR_CONTRACT_PAUSED

    // Unpause vault
    simnet.callPublicFn("obelisk-vault", "set-paused", [Cl.bool(false)], deployer);
    const createSuccess = simnet.callPublicFn("obelisk-vault", "create-epoch", [Cl.uint(maturityBlock)], deployer);
    expect(createSuccess.result).toBeOk(Cl.uint(1));
  });
});
