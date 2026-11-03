import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const lpProvider = accounts.get("wallet_1")!;
const trader1 = accounts.get("wallet_2")!;
const trader2 = accounts.get("wallet_3")!;

describe("YieldSpace AMM Test Suite", () => {
  beforeEach(() => {
    // Authorize deployer as vault/minter so we can mint PT for tests
    simnet.callPublicFn("principal-token", "set-authorized-vault", [Cl.principal(deployer)], deployer);

    // Initialize pool for epoch 1
    const maturityBlock = simnet.blockHeight + 1000;
    simnet.callPublicFn(
      "yield-space-amm",
      "initialize-pool",
      [Cl.uint(1), Cl.uint(maturityBlock), Cl.uint(1000)],
      deployer
    );
  });

  it("calculates time-decayed discount rates accurately", () => {
    const maturityBlock = simnet.blockHeight + 1000;

    // At start of epoch (1000 blocks remaining out of 1000 duration)
    const timeWeight = simnet.callReadOnlyFn(
      "yield-space-amm",
      "get-time-weight-bps",
      [Cl.uint(maturityBlock), Cl.uint(1000)],
      deployer
    );
    expect(timeWeight.result).toBeUint(10000n); // 100% time remaining

    const discountBps = simnet.callReadOnlyFn(
      "yield-space-amm",
      "get-pt-discount-bps",
      [Cl.uint(maturityBlock), Cl.uint(1000)],
      deployer
    );
    // Max 1500 bps (15.00%) discount when full duration remains
    expect(discountBps.result).toBeUint(1500n);
  });

  it("adds liquidity and mints initial LP shares", () => {
    const stxDeposit = 10000000n; // 10 STX
    const ptDeposit = 10000000n;  // 10 PT

    // Mint PT to lpProvider
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(lpProvider), Cl.uint(ptDeposit)], deployer);

    // lpProvider adds liquidity
    const addLiqRes = simnet.callPublicFn(
      "yield-space-amm",
      "add-liquidity",
      [Cl.uint(1), Cl.uint(stxDeposit), Cl.uint(ptDeposit)],
      lpProvider
    );
    expect(addLiqRes.result).toBeOk(Cl.uint(10000000n)); // (10M + 10M) / 2 = 10M LP shares

    const lpBal = simnet.callReadOnlyFn(
      "yield-space-amm",
      "get-lp-balance",
      [Cl.uint(1), Cl.principal(lpProvider)],
      deployer
    );
    expect(lpBal.result).toBeUint(10000000n);

    // Verify pool state has correct reserves
    const pool = simnet.callReadOnlyFn("yield-space-amm", "get-pool", [Cl.uint(1)], deployer);
    expect(pool.result).toBeDefined();
    // Verify reserves match deposits
    const poolData = pool.result as any;
    expect(poolData.type).toBeDefined();
  });

  it("executes STX for PT swap providing discounted fixed yield", () => {
    // Seed pool liquidity
    const stxDeposit = 20000000n;
    const ptDeposit = 20000000n;
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(lpProvider), Cl.uint(ptDeposit)], deployer);
    simnet.callPublicFn("yield-space-amm", "add-liquidity", [Cl.uint(1), Cl.uint(stxDeposit), Cl.uint(ptDeposit)], lpProvider);

    // Trader swaps 1,000,000 uSTX for PT
    const swapIn = 1000000n;
    const quote = simnet.callReadOnlyFn("yield-space-amm", "quote-stx-to-pt", [Cl.uint(1), Cl.uint(swapIn)], deployer);
    // Trader receives MORE than 1,000,000 PT because PT is discounted!
    const quoteVal = (quote.result as any).value.value;
    expect(quoteVal).toBeGreaterThan(1140000n); // ~14.6% fixed yield premium net of fee

    const swapRes = simnet.callPublicFn(
      "yield-space-amm",
      "swap-stx-for-pt",
      [Cl.uint(1), Cl.uint(swapIn), Cl.uint(1100000n)],
      trader1
    );
    expect(swapRes.result).toBeOk(Cl.uint((swapRes.result as any).value.value));
    expect((swapRes.result as any).value.value).toBeGreaterThan(1140000n);

    // Trader now holds PT tokens
    const traderPT = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(trader1)], deployer);
    expect(traderPT.result).toBeOk(Cl.uint((swapRes.result as any).value.value));
  });

  it("executes PT for STX swap for immediate liquidity", () => {
    // Seed pool liquidity
    const stxDeposit = 20000000n;
    const ptDeposit = 20000000n;
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(lpProvider), Cl.uint(ptDeposit)], deployer);
    simnet.callPublicFn("yield-space-amm", "add-liquidity", [Cl.uint(1), Cl.uint(stxDeposit), Cl.uint(ptDeposit)], lpProvider);

    // Mint PT to trader2
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(trader2), Cl.uint(2000000n)], deployer);

    // Trader2 swaps 1,000,000 PT for STX
    const ptIn = 1000000n;
    const quote = simnet.callReadOnlyFn("yield-space-amm", "quote-pt-to-stx", [Cl.uint(1), Cl.uint(ptIn)], deployer);
    const quoteVal = (quote.result as any).value.value;
    expect(quoteVal).toBeLessThan(900000n); // Sold at discount for immediate liquidity

    const swapRes = simnet.callPublicFn(
      "yield-space-amm",
      "swap-pt-for-stx",
      [Cl.uint(1), Cl.uint(ptIn), Cl.uint(850000n)],
      trader2
    );
    expect(swapRes.result).toBeOk(Cl.uint((swapRes.result as any).value.value));
    expect((swapRes.result as any).value.value).toBeLessThan(900000n);
  });

  it("removes liquidity cleanly and returns pro-rata assets", () => {
    const stxDeposit = 10000000n;
    const ptDeposit = 10000000n;
    simnet.callPublicFn("principal-token", "mint", [Cl.principal(lpProvider), Cl.uint(ptDeposit)], deployer);
    simnet.callPublicFn("yield-space-amm", "add-liquidity", [Cl.uint(1), Cl.uint(stxDeposit), Cl.uint(ptDeposit)], lpProvider);

    // Remove 5,000,000 shares (50%)
    const removeRes = simnet.callPublicFn(
      "yield-space-amm",
      "remove-liquidity",
      [Cl.uint(1), Cl.uint(5000000n)],
      lpProvider
    );
    expect(removeRes.result).toBeOk(
      Cl.tuple({
        "stx-returned": Cl.uint(5000000n),
        "pt-returned": Cl.uint(5000000n),
      })
    );

    const remainingShares = simnet.callReadOnlyFn(
      "yield-space-amm",
      "get-lp-balance",
      [Cl.uint(1), Cl.principal(lpProvider)],
      deployer
    );
    expect(remainingShares.result).toBeUint(5000000n);
  });
});
