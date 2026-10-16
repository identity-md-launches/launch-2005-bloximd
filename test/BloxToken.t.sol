// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MiniTest} from "./utils/MiniTest.sol";
import {BloxToken} from "../src/BloxToken.sol";

contract BloxTokenTest is MiniTest {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE7D);

    BloxToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new BloxToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "BloxIMD", "name");
        assertEq(token.symbol(), "BLOX", "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
    }

    function test_wholeSupplyMintedOnceToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "supply constant");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "deployer balance");
        assertEq(token.balanceOf(address(this)), 0, "nobody else holds any");
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        new BloxToken();
    }

    function test_noMintOwnerOrPauseEntryPoints() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, SUPPLY),
            abi.encodeWithSignature("mint(uint256)", SUPPLY),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("burnFrom(address,uint256)", DEPLOYER, 1),
            abi.encodeWithSignature("blacklist(address)", DEPLOYER)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(calls[i]);
            assertTrue(!ok, "an admin entry point exists");
        }
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "deployer balance changed");
    }

    // ---------------------------------------------------------------- transfer

    function test_transfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, ALICE, 100e18);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 100e18), "returned false");
        assertEq(token.balanceOf(ALICE), 100e18, "recipient");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 100e18, "sender");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(DEPLOYER, 5e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "self transfer changed balance");
    }

    function test_transferZeroAmount() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0), "zero transfer failed");
        assertEq(token.balanceOf(BOB), 0, "bob");
    }

    function test_revertWhen_transferExceedsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, ALICE, uint256(10), uint256(11)));
        vm.prank(ALICE);
        token.transfer(BOB, 11);
    }

    function test_revertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- approve and transferFrom

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, SPENDER, 50e18);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, 50e18), "approve returned false");
        assertEq(token.allowance(DEPLOYER, SPENDER), 50e18, "allowance");

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 20e18), "transferFrom returned false");
        assertEq(token.balanceOf(BOB), 20e18, "bob");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 20e18, "deployer");
        assertEq(token.allowance(DEPLOYER, SPENDER), 30e18, "allowance not reduced");
    }

    function test_infiniteAllowanceIsNotReduced() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1e18);
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max, "infinite allowance reduced");
    }

    function test_approveOverwrites() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 10);
        token.approve(SPENDER, 3);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 3, "allowance not overwritten");
    }

    function test_revertWhen_transferFromWithoutAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, SPENDER, 1);
    }

    function test_revertWhen_transferFromExceedsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 5);
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(5), uint256(6))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 6);
    }

    function test_revertWhen_transferFromExceedsBalance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, ALICE, uint256(0), uint256(1)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_revertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), before + amount, "recipient");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "sender");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    function testFuzz_transferFromSpendsExactAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - amount, "allowance");
        assertEq(token.balanceOf(ALICE), amount, "alice");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    function testFuzz_revertWhen_transferMoreThanBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
    }
}
