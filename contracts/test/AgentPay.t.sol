// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {IAgentRegistry} from "../src/IAgentRegistry.sol";
import {MiniIdentityRegistry} from "../script/Deploy.s.sol";

/// @dev Minimal EIP-3009 token matching tUSD8's interface, for unit tests without a fork.
contract Mock3009 {
    string public name = "MockUSD8";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 => bool) public authorizationState;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) { balanceOf[msg.sender] -= v; balanceOf[to] += v; emit Transfer(msg.sender, to, v); return true; }
    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v; balanceOf[f] -= v; balanceOf[t] += v; emit Transfer(f, t, v); return true;
    }

    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes("2")), block.chainid, address(this)
        ));
    }

    bytes32 public AUTH_TYPEHASH = keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    function authorizationDigest(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce) external view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(AUTH_TYPEHASH, from, to, value, validAfter, validBefore, nonce))));
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter, uint256 validBefore,
        bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    ) external {
        require(balanceOf[from] >= value, "insufficient");
        require(block.timestamp > validAfter && block.timestamp < validBefore, "window");
        require(!authorizationState[nonce], "used");
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", DOMAIN_SEPARATOR,
            keccak256(abi.encode(
                keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
                from, to, value, validAfter, validBefore, nonce)
            )));
        address sign = ecrecover(digest, v, r, s);
        require(sign == from, "bad sig");
        authorizationState[nonce] = true;
        balanceOf[from] -= value; balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

contract AgentPayTest is Test {
    Mock3009 token;
    MiniIdentityRegistry registry;
    AgentPay pay_;
    uint256 constant AGENT = 1;
    address agentOwner = makeAddr("agentOwner");
    address client = makeAddr("client");
    address treasury = makeAddr("treasury");

    function setUp() public {
        token = new Mock3009();
        registry = new MiniIdentityRegistry();
        pay_ = new AgentPay(IERC20(address(token)), IAgentRegistry(address(registry)), treasury);
        vm.prank(agentOwner);
        registry.register("https://agent.example/agent-card.json");
        vm.prank(agentOwner);
        pay_.setOffer(AGENT, 5_000_000, true); // 5 tUSD8
        token.mint(client, 100e6);
    }

    function test_pay_movesFundsAndRecords() public {
        bytes32 jobId = keccak256("job-1");
        vm.startPrank(client);
        token.approve(address(pay_), type(uint256).max);
        pay_.pay(jobId, AGENT, keccak256("spec"));
        vm.stopPrank();
        (uint256 aId, address c, uint256 amt,, ) = pay_.jobs(jobId);
        assertEq(aId, AGENT); assertEq(c, client); assertEq(amt, 5_000_000);
        assertEq(token.balanceOf(agentOwner), 5_000_000 - 25_000);
        assertEq(token.balanceOf(treasury), 25_000);
        assertEq(pay_.totalEarned(AGENT), 5_000_000);
        assertEq(pay_.jobCount(AGENT), 1);
    }

    function test_pay_revertsOnSecondPayment() public {
        bytes32 jobId = keccak256("job-2");
        vm.startPrank(client);
        token.approve(address(pay_), type(uint256).max);
        pay_.pay(jobId, AGENT, keccak256("spec"));
        vm.expectRevert(abi.encodeWithSelector(AgentPay.AlreadyPaid.selector, jobId));
        pay_.pay(jobId, AGENT, keccak256("spec"));
        vm.stopPrank();
    }

    function test_setOffer_onlyAgentOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.NotAgentOwner.selector, AGENT, client));
        pay_.setOffer(AGENT, 1, true);
    }

    function test_inactiveOfferRejectsPayment() public {
        vm.prank(agentOwner);
        pay_.setOffer(AGENT, 5_000_000, false);
        vm.startPrank(client);
        token.approve(address(pay_), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(AgentPay.InactiveOffer.selector, AGENT));
        pay_.pay(keccak256("job-3"), AGENT, keccak256("spec"));
        vm.stopPrank();
    }

    function test_payWithAuthorization_gasless() public {
        // gasless client: signs EIP-3009 off-chain, relayer (this test) submits
        uint256 clientPk = 0xA11CE;
        address gaslessClient = vm.addr(clientPk);
        token.mint(gaslessClient, 10e6);

        bytes32 jobId = keccak256("job-gasless");
        uint256 price = 5_000_000;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = pay_.authorizationNonce(jobId);

        bytes32 digest = token.authorizationDigest(gaslessClient, address(pay_), price, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(clientPk, digest);

        // relayer calls; gaslessClient never signs a transaction
        pay_.payWithAuthorization(jobId, AGENT, gaslessClient, keccak256("spec"), validAfter, validBefore, v, r, s);
        (uint256 aId, address c, uint256 amt,, ) = pay_.jobs(jobId);
        assertEq(aId, AGENT); assertEq(c, gaslessClient); assertEq(amt, price);
        assertEq(token.balanceOf(agentOwner), price - price / 200);
    }
}
