// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {IAgentRegistry} from "../src/IAgentRegistry.sol";

/// @notice Minimal ERC-8004 IdentityRegistry for chains without a canonical deployment.
///         Interface-compatible with the erc-8004 reference implementation (register /
///         ownerOf / getAgentWallet), so AgentPay works with the real one when it ships
///         on Aevum — just redeploy pointing at it.
contract MiniIdentityRegistry {
    struct Agent { address owner; string agentURI; address wallet; }
    uint256 public nextId = 1;
    mapping(uint256 => Agent) public agents;

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = nextId++;
        agents[agentId] = Agent(msg.sender, agentURI, msg.sender);
        emit Registered(agentId, agentURI, msg.sender);
    }
    function ownerOf(uint256 agentId) external view returns (address) { return agents[agentId].owner; }
    function getAgentWallet(uint256 agentId) external view returns (address) { return agents[agentId].wallet; }
    function agentURI(uint256 agentId) external view returns (string memory) { return agents[agentId].agentURI; }
}

contract Deploy is Script {
    address constant AEVUM_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    uint256 constant ANVIL_CHAIN = 31337;
    uint256 constant FORK_CHAIN = 440050;
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    function run() external returns (AgentPay agentPay, address token, address registry) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address treasury = vm.envOr("TREASURY", deployer);

        if (AEVUM_TUSD8.code.length > 0) {
            token = AEVUM_TUSD8;
        } else {
            require(block.chainid == ANVIL_CHAIN, "tUSD8 not found. Check RPC (Aevum testnet is 44005).");
            revert("Use fork mode (make fork) for local testing with real tUSD8");
        }

        registry = address(new MiniIdentityRegistry());
        agentPay = new AgentPay(IERC20(token), IAgentRegistry(registry), treasury);
        vm.stopBroadcast();

        console.log("chainId   ", block.chainid);
        console.log("tUSD8     ", token);
        console.log("Registry  ", registry);
        console.log("AgentPay  ", address(agentPay));
        console.log("treasury  ", treasury);
    }

    function isAnvilAccount(address a) internal pure returns (bool) {
        for (uint32 i = 0; i < 10; i++) {
            if (vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)) == a) return true;
        }
        return false;
    }
}

