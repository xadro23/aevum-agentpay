// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentRegistry} from "./IAgentRegistry.sol";

/// @notice EIP-3009 (USDC-style) signed transfers. tUSD8 on Aevum implements this.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title AgentPay
/// @notice Agent-to-agent stablecoin payments on QDay Aevum. An ERC-8004 agent lists a
///         priced service; a client (human or another agent) pays tUSD8 per completed job
///         and the payment itself becomes the reputation anchor: every settled job emits
///         JobPaid, which the app uses to auto-give ERC-8004 feedback (rate the agent).
///
///         Two payment modes, mirroring Checkout.sol:
///          1. pay: client approves this contract and calls pay (client pays gas).
///          2. payWithAuthorization: client signs an EIP-3009 message off-chain; any relayer
///             submits it — the client agent needs no native tQDAY gas at all.
///
///         Jobs are escrow-free and push-based: the agent posts an offer, client pays on
///         delivery, contract emits the receipt. Disputes are handled off-chain (v0.1);
///         a later version can add stake-secured validation per ERC-8004 trust models.
contract AgentPay {
    using SafeERC20 for IERC20;

    struct Job {
        uint256 agentId;      // ERC-8004 agent offering the service
        address client;       // who paid
        uint256 amount;       // tUSD8 (6 decimals)
        uint64  paidAt;
        bytes32 requestHash;  // keccak256 of the off-chain job spec (what was ordered)
    }

    struct Offer {
        uint256 price;        // per job, in tUSD8
        bool active;
    }

    IERC20 public immutable token;
    IAgentRegistry public immutable registry;
    address public treasury; // small protocol fee destination (0.5%)

    uint256 public constant FEE_BPS = 50; // 0.5%

    mapping(uint256 agentId => Offer) public offers;
    mapping(bytes32 jobId => Job) public jobs;
    mapping(uint256 agentId => uint256) public totalEarned;
    mapping(uint256 agentId => uint256) public jobCount;

    event OfferSet(uint256 indexed agentId, uint256 price, bool active);
    event JobPaid(
        bytes32 indexed jobId,
        uint256 indexed agentId,
        address indexed client,
        address agentWallet,
        uint256 amount,
        uint256 fee,
        bytes32 requestHash
    );

    error NotAgentOwner(uint256 agentId, address caller);
    error InactiveOffer(uint256 agentId);
    error ZeroAmount();
    error ZeroAddress();

    constructor(IERC20 token_, IAgentRegistry registry_, address treasury_) {
        if (address(token_) == address(0) || address(registry_) == address(0) || treasury_ == address(0))
            revert ZeroAddress();
        token = token_;
        registry = registry_;
        treasury = treasury_;
    }

    /// @notice An ERC-8004 agent (its on-chain owner) lists/updates a priced service offer.
    function setOffer(uint256 agentId, uint256 price, bool active) external {
        if (registry.ownerOf(agentId) != msg.sender) revert NotAgentOwner(agentId, msg.sender);
        if (active && price == 0) revert ZeroAmount();
        offers[agentId] = Offer(price, active);
        emit OfferSet(agentId, price, active);
    }

    /// @notice Client pays directly (approve first). `jobId` must be unique per job.
    function pay(bytes32 jobId, uint256 agentId, bytes32 requestHash) external {
        uint256 price = _settle(jobId, agentId, msg.sender, requestHash);
        token.safeTransferFrom(msg.sender, address(this), price);
        _payout(agentId, price, msg.sender, jobId, requestHash);
    }

    /// @notice Gasless path: client agent signs EIP-3009 ReceiveWithAuthorization off-chain;
    ///         any relayer submits. Signature nonce must be authorizationNonce(jobId).
    function payWithAuthorization(
        bytes32 jobId,
        uint256 agentId,
        address from,
        bytes32 requestHash,
        uint256 validAfter,
        uint256 validBefore,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        uint256 price = _settle(jobId, agentId, from, requestHash);
        _pullAuthorized(from, price, jobId, validAfter, validBefore, v, r, s);
        _payout(agentId, price, from, jobId, requestHash);
    }

    function _pullAuthorized(
        address from,
        uint256 price,
        bytes32 jobId,
        uint256 validAfter,
        uint256 validBefore,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        IERC3009(address(token)).receiveWithAuthorization(
            from, address(this), price, validAfter, validBefore, authorizationNonce(jobId), v, r, s
        );
    }

    function authorizationNonce(bytes32 jobId) public pure returns (bytes32) {
        return keccak256(abi.encode("agentpay.auth.nonce", jobId));
    }

    function _settle(bytes32 jobId, uint256 agentId, address client, bytes32 requestHash) internal returns (uint256 price) {
        Offer memory o = offers[agentId];
        if (!o.active) revert InactiveOffer(agentId);
        if (jobs[jobId].paidAt != 0) revert AlreadyPaid(jobId);
        jobs[jobId] = Job(agentId, client, o.price, uint64(block.timestamp), requestHash);
        price = o.price;
    }

    error AlreadyPaid(bytes32 jobId);

    function _payout(uint256 agentId, uint256 amount, address client, bytes32 jobId, bytes32 requestHash) internal {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        address wallet = registry.getAgentWallet(agentId);
        if (wallet == address(0)) wallet = registry.ownerOf(agentId);
        token.safeTransfer(wallet, amount - fee);
        if (fee > 0) token.safeTransfer(treasury, fee);
        unchecked { totalEarned[agentId] += amount; jobCount[agentId] += 1; }
        emit JobPaid(jobId, agentId, client, wallet, amount, fee, requestHash);
    }
}
