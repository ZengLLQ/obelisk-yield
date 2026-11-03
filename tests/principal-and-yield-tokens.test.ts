import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const user1 = accounts.get("wallet_1")!;
const user2 = accounts.get("wallet_2")!;

describe("Principal Token (PT-STX) & Yield Token (YT-STX) Test Suite", () => {
  it("exposes valid SIP-010 metadata for Principal Token", () => {
    const name = simnet.callReadOnlyFn("principal-token", "get-name", [], deployer);
    expect(name.result).toBeOk(Cl.stringAscii("Obelisk Principal Token"));

    const symbol = simnet.callReadOnlyFn("principal-token", "get-symbol", [], deployer);
    expect(symbol.result).toBeOk(Cl.stringAscii("PT-STX"));

    const decimals = simnet.callReadOnlyFn("principal-token", "get-decimals", [], deployer);
    expect(decimals.result).toBeOk(Cl.uint(6));

    const supply = simnet.callReadOnlyFn("principal-token", "get-total-supply", [], deployer);
    expect(supply.result).toBeOk(Cl.uint(0));
  });

  it("exposes valid SIP-010 metadata for Yield Token", () => {
    const name = simnet.callReadOnlyFn("yield-token", "get-name", [], deployer);
    expect(name.result).toBeOk(Cl.stringAscii("Obelisk Yield Token"));

    const symbol = simnet.callReadOnlyFn("yield-token", "get-symbol", [], deployer);
    expect(symbol.result).toBeOk(Cl.stringAscii("YT-STX"));

    const decimals = simnet.callReadOnlyFn("yield-token", "get-decimals", [], deployer);
    expect(decimals.result).toBeOk(Cl.uint(6));

    const supply = simnet.callReadOnlyFn("yield-token", "get-total-supply", [], deployer);
    expect(supply.result).toBeOk(Cl.uint(0));
  });

  it("enforces strict minting authority for PT and YT tokens", () => {
    // Unauthorized caller cannot mint
    const mintPT = simnet.callPublicFn(
      "principal-token",
      "mint",
      [Cl.principal(user1), Cl.uint(1000000)],
      user2
    );
    expect(mintPT.result).toBeErr(Cl.uint(300)); // ERR_NOT_AUTHORIZED

    const mintYT = simnet.callPublicFn(
      "yield-token",
      "mint",
      [Cl.principal(user1), Cl.uint(1000000)],
      user2
    );
    expect(mintYT.result).toBeErr(Cl.uint(300)); // ERR_NOT_AUTHORIZED

    // Authorized owner/vault can mint
    const authMintPT = simnet.callPublicFn(
      "principal-token",
      "mint",
      [Cl.principal(user1), Cl.uint(5000000)],
      deployer
    );
    expect(authMintPT.result).toBeOk(Cl.bool(true));

    const balPT = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(user1)], deployer);
    expect(balPT.result).toBeOk(Cl.uint(5000000));
  });

  it("executes standard SIP-010 transfers cleanly", () => {
    // Mint 5,000,000 PT to user1 first
    simnet.callPublicFn(
      "principal-token",
      "mint",
      [Cl.principal(user1), Cl.uint(5000000)],
      deployer
    );

    // user1 transfers 2,000,000 PT to user2
    const transferRes = simnet.callPublicFn(
      "principal-token",
      "transfer",
      [
        Cl.uint(2000000),
        Cl.principal(user1),
        Cl.principal(user2),
        Cl.none(),
      ],
      user1
    );
    expect(transferRes.result).toBeOk(Cl.bool(true));

    const bal1 = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(user1)], deployer);
    expect(bal1.result).toBeOk(Cl.uint(3000000));

    const bal2 = simnet.callReadOnlyFn("principal-token", "get-balance", [Cl.principal(user2)], deployer);
    expect(bal2.result).toBeOk(Cl.uint(2000000));
  });
});
