// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-8004 Identity Registry surface.
///         Full spec: https://github.com/erc-8004/erc-8004-contracts
interface IAgentRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentWallet(uint256 agentId) external view returns (address);
}
