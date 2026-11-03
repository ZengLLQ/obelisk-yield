import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const user1 = accounts.get("wallet_1")!;
const user2 = accounts.get("wallet_2")!;

describe("Mock sBTC Token Test Suite", () => {
  it("exposes valid SIP-010 metadata for Mock sBTC", () => {
    const name = simnet.callReadOnlyFn("mock-token", "get-name", [], deployer);
    expect(name.result).toBeOk(Cl.stringAscii("Mock sBTC Token"));

    const symbol = simnet.callReadOnlyFn("mock-token", "get-symbol", [], deployer);
    expect(symbol.result).toBeOk(Cl.stringAscii("msBTC"));

    const decimals = simnet.callReadOnlyFn("mock-token", "get-decimals", [], deployer);
    expect(decimals.result).toBeOk(Cl.uint(8));

    const uri = simnet.callReadOnlyFn("mock-token", "get-token-uri", [], deployer);
    expect(uri.result).toBeOk(Cl.some(Cl.stringUtf8("https://obelisk.finance/metadata/msbtc.json")));
  });

  it("mints, transfers, and burns tokens accurately", () => {
    // Mint 100,000,000 satoshis (1 BTC) to user1
    const mintRes = simnet.callPublicFn(
      "mock-token",
      "mint",
      [Cl.principal(user1), Cl.uint(100000000)],
      deployer
    );
    expect(mintRes.result).toBeOk(Cl.bool(true));

    const bal1 = simnet.callReadOnlyFn("mock-token", "get-balance", [Cl.principal(user1)], deployer);
    expect(bal1.result).toBeOk(Cl.uint(100000000));

    // Transfer 25,000,000 satoshis to user2
    const transferRes = simnet.callPublicFn(
      "mock-token",
      "transfer",
      [
        Cl.uint(25000000),
        Cl.principal(user1),
        Cl.principal(user2),
        Cl.none(),
      ],
      user1
    );
    expect(transferRes.result).toBeOk(Cl.bool(true));

    const bal2 = simnet.callReadOnlyFn("mock-token", "get-balance", [Cl.principal(user2)], deployer);
    expect(bal2.result).toBeOk(Cl.uint(25000000));

    // User2 burns 5,000,000 satoshis
    const burnRes = simnet.callPublicFn("mock-token", "burn", [Cl.uint(5000000)], user2);
    expect(burnRes.result).toBeOk(Cl.bool(true));

    const bal2AfterBurn = simnet.callReadOnlyFn("mock-token", "get-balance", [Cl.principal(user2)], deployer);
    expect(bal2AfterBurn.result).toBeOk(Cl.uint(20000000));
  });
});
