# AevumPay — Agent-to-Agent Stablecoin Payments on QDay Aevum

**Aevum Builder Challenge #1 submission** (QDay, deadline 11 Dec 2026)

AgentPay is a smart-contract layer where **ERC-8004 agents sell services for tUSD8** and settle payments **gaslessly** via EIP-3009. Payments double as reputation anchors: every settled job emits `JobPaid`, tying tUSD8 flow to on-chain agent identity.

## Why this fits the challenge

- **Stablecoin payment app**: real tUSD8 (USDC-style, 6 decimals, EIP-3009) on Aevum testnet (chain 44005)
- **ERC-8004 agentic payments**: agents are registered on an Identity Registry (mini registry interface-compatible with the erc-8004 reference; swap-in ready for the canonical one); the agent's `agentWallet` (or owner) receives payouts; payment receipts anchor reputation
- **Gasless clients**: client agents sign an EIP-3009 `ReceiveWithAuthorization` off-chain; any relayer submits — a client agent needs **zero tQDAY gas** to pay

## How it works

```
Agent (ERC-8004 id #1) ── setOffer(1, 5 tUSD8, active) ──┐
                                                          ▼
Client ── pay(jobId, 1, requestHash) ────────────────► AgentPay
   or                                                    │
Client signs EIP-3009 ── relayer ─► payWithAuthorization  │
                                                          ▼
                          agentWallet gets 99.5% + treasury 0.5% + JobPaid event
```

- `setOffer(agentId, price, active)` — only the registry `ownerOf(agentId)` can list a service
- `pay(jobId, agentId, requestHash)` — direct path, client pays gas
- `payWithAuthorization(...)` — gasless path, nonce bound to the jobId (`authorizationNonce`)
- Each `jobId` pays exactly once; `requestHash` commits the off-chain job spec
- Fee: 50 bps (0.5%) to treasury; the rest forwards to the agent wallet

## Status

- Contracts built + **5/5 unit tests pass** + fork test against real tUSD8 passes
- **Deploy pending**: Aevum faucet requires holding ≥0.0001 ETH on Ethereum mainnet (anti-abuse); deployment to Aevum testnet happens as soon as test gas arrives
- Web demo app: `web/` (Next.js from the starter-kit pattern) — setup checker, agent registration, offer listing, direct + gasless payment flows, receipts feed

## Layout

```
contracts/
  src/AgentPay.sol         the protocol
  src/IAgentRegistry.sol   ERC-8004 IdentityRegistry surface
  script/Deploy.s.sol      MiniIdentityRegistry + AgentPay deployer
  test/AgentPay.t.sol      unit tests (Mock3009)
  test/Fork.t.sol          fork test vs real tUSD8
web/                       demo app
```

## Commands

```shell
cd contracts && forge build && forge test
forge test --match-path 'test/Fork.t.sol' --fork-url https://rpc-test.qday.info
make -C ~/aevum-starter-kit fork   # local Aevum copy for demos
```

## License

MIT
