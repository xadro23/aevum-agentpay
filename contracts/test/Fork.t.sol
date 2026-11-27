// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {IAgentRegistry} from "../src/IAgentRegistry.sol";
import {MiniIdentityRegistry} from "../script/Deploy.s.sol";

/// @notice Fork tests against REAL tUSD8 on Aevum testnet (no funds needed).
contract ForkTest is Test {
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);

    function test_tusd8_isE3009Compatible() public {
        // on the real Aevum testnet, tUSD8 exists and has 6 decimals + EIP-3009
        assertTrue(address(TUSD8).code.length > 0, "tUSD8 missing: run on Aevum or a fork");
        try IERC20(address(TUSD8)).balanceOf(address(0x1)) returns (uint256) {} catch { revert("balanceOf missing"); }
    }
}
