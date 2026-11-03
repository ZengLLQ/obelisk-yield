import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const reporter1 = accounts.get("wallet_1")!;
const unauthorizedUser = accounts.get("wallet_2")!;

describe("ObeliskOracle Contract Test Suite", () => {
  it("initializes with deployer as default authorized reporter and valid baseline feeds", () => {
    const isDeployerAuth = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "is-reporter-authorized",
      [Cl.principal(deployer)],
      deployer
    );
    expect(isDeployerAuth.result).toBeBool(true);

    const summary = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "get-oracle-summary",
      [],
      deployer
    );
    expect(summary.result).toBeOk(
      Cl.tuple({
        "stx-usd": Cl.uint(2500000),      // $2.50
        "btc-usd": Cl.uint(95000000000),  // $95,000
        "pox-apy-bps": Cl.uint(850),      // 8.50%
        "last-updated": Cl.uint(0),
        "update-count": Cl.uint(0),
        stale: Cl.bool(false),
      })
    );
  });

  it("allows authorized reporter to submit new feed data", () => {
    // Add reporter1
    const addRes = simnet.callPublicFn(
      "obelisk-oracle",
      "add-reporter",
      [Cl.principal(reporter1)],
      deployer
    );
    expect(addRes.result).toBeOk(Cl.bool(true));

    // Submit valid update within deviation bounds
    const submitRes = simnet.callPublicFn(
      "obelisk-oracle",
      "submit-oracle-data",
      [
        Cl.uint(2600000),     // $2.60 STX (+4% within 30% limit)
        Cl.uint(98000000000), // $98,000 BTC
        Cl.uint(900),         // 9.00% APY
      ],
      reporter1
    );
    expect(submitRes.result).toBeOk(Cl.uint(1));

    // Verify updated values
    const stxPrice = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "get-stx-usd",
      [],
      deployer
    );
    expect(stxPrice.result).toBeOk(Cl.uint(2600000));

    const apy = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "get-pox-apy-bps",
      [],
      deployer
    );
    expect(apy.result).toBeOk(Cl.uint(900));
  });

  it("rejects price submission from unauthorized callers", () => {
    const submitRes = simnet.callPublicFn(
      "obelisk-oracle",
      "submit-oracle-data",
      [Cl.uint(2700000), Cl.uint(100000000000), Cl.uint(950)],
      unauthorizedUser
    );
    expect(submitRes.result).toBeErr(Cl.uint(100)); // ERR_NOT_AUTHORIZED
  });

  it("triggers circuit breaker when price swing exceeds maximum allowable deviation", () => {
    // Initial submission to set last-updated-block
    simnet.callPublicFn(
      "obelisk-oracle",
      "submit-oracle-data",
      [Cl.uint(2500000), Cl.uint(95000000000), Cl.uint(850)],
      deployer
    );

    // Try to swing STX price from $2.50 to $4.00 (>50% jump, exceeds 3000 bps)
    const swingRes = simnet.callPublicFn(
      "obelisk-oracle",
      "submit-oracle-data",
      [Cl.uint(4000000), Cl.uint(95000000000), Cl.uint(850)],
      deployer
    );
    expect(swingRes.result).toBeErr(Cl.uint(103)); // ERR_CIRCUIT_BREAKER_TRIGGERED
  });

  it("detects staleness when chain tip advances past max staleness threshold", () => {
    // Initial submission
    simnet.callPublicFn(
      "obelisk-oracle",
      "submit-oracle-data",
      [Cl.uint(2500000), Cl.uint(95000000000), Cl.uint(850)],
      deployer
    );

    // Advance blocks past 288 blocks threshold
    simnet.mineEmptyBlocks(300);

    const isStale = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "is-stale",
      [],
      deployer
    );
    expect(isStale.result).toBeBool(true);

    const stxQuery = simnet.callReadOnlyFn(
      "obelisk-oracle",
      "get-stx-usd",
      [],
      deployer
    );
    expect(stxQuery.result).toBeErr(Cl.uint(101)); // ERR_ORACLE_STALE
  });
});
