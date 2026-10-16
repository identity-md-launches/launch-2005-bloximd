// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MiniTest, Vm} from "./utils/MiniTest.sol";
import {BloxToken} from "../src/BloxToken.sol";

/// @notice Stands in for the launch factory: deploys the token inside one call so the whole mint
/// lands on a contract, the way `ProjectFactory.launchCustom` receives it, and then forwards it.
contract FactoryProbe {
    BloxToken public token;

    function launch() external returns (BloxToken deployed) {
        deployed = new BloxToken();
        token = deployed;
    }

    function forward(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Adversarial edge cases for BloxToken: the inputs the happy path never sends. Zero, one
/// wei, the whole supply, the type maximum, the same call twice, callers the code did not expect,
/// and every revert path with its exact error payload.
/// forge-config: default.fuzz.runs = 1000
contract BloxTokenEdgesTest is MiniTest {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MAX = type(uint256).max;
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE7D);

    BloxToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new BloxToken();
    }

    // ---------------------------------------------------------------- deployment

    function test_supplyIsExactlyOneBillionTimesTenPow18() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18, "supply");
        assertEq(token.totalSupply(), 1000000000000000000000000000, "supply in minor units");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "immutable disagrees with constant");
        assertEq(token.totalSupply() % 10 ** 18, 0, "supply is not a whole number of tokens");
    }

    function test_deployedFromAContractInOneCallMintsToThatContract() public {
        FactoryProbe factory = new FactoryProbe();
        BloxToken launched = factory.launch();
        assertEq(launched.totalSupply(), SUPPLY, "supply");
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory does not hold the supply");
        assertEq(launched.balanceOf(address(this)), 0, "the test contract received tokens");
        assertEq(launched.balanceOf(address(launched)), 0, "the token holds its own supply");
        // The factory forwards a tenth of the supply whole: no fee, no burn.
        uint256 tenth = SUPPLY / 10;
        assertTrue(factory.forward(ALICE, tenth), "forward returned false");
        assertEq(launched.balanceOf(ALICE), tenth, "the forwarded share arrived short");
        assertEq(launched.balanceOf(address(factory)), SUPPLY - tenth, "the factory kept more than it should");
        assertEq(launched.totalSupply(), SUPPLY, "forwarding changed the supply");
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        BloxToken second = new BloxToken();
        assertEq(second.balanceOf(ALICE), SUPPLY, "second deployer");
        assertEq(second.balanceOf(DEPLOYER), 0, "first deployer holds the second token");
        assertEq(token.balanceOf(ALICE), 0, "second deployer holds the first token");
        assertEq(token.totalSupply() + second.totalSupply(), 2 * SUPPLY, "supplies");
    }

    function test_constructorEmitsExactlyOneLog() public {
        vm.recordLogs();
        vm.prank(DEPLOYER);
        new BloxToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emitted a different number of logs");
        assertEq(logs[0].topics.length, 3, "topics");
        assertEq(logs[0].topics[0], TRANSFER_TOPIC, "not a Transfer");
        assertEq(logs[0].topics[1], bytes32(0), "mint must come from the zero address");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(DEPLOYER))), "mint must go to the deployer");
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY, "minted amount");
    }

    function test_metadataIsStableAcrossCalls() public view {
        assertEq(token.name(), "BloxIMD", "name");
        assertEq(token.name(), token.name(), "name is not deterministic");
        assertEq(bytes(token.name()).length, 7, "name length");
        assertEq(token.symbol(), "BLOX", "symbol");
        assertEq(bytes(token.symbol()).length, 4, "symbol length");
        assertEq(uint256(token.decimals()), 18, "decimals");
    }

    // ---------------------------------------------------------------- unexpected callers and calldata

    function test_tokenRejectsEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool okPlain,) = address(token).call{value: 1}("");
        assertTrue(!okPlain, "a plain ether transfer was accepted");
        (bool okSelector,) = address(token).call{value: 1}(abi.encodeCall(BloxToken.transfer, (ALICE, 0)));
        assertTrue(!okSelector, "a non-payable function accepted ether");
        (bool okUnknown,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertTrue(!okUnknown, "an unknown selector did not revert");
        (bool okEmpty,) = address(token).call("");
        assertTrue(!okEmpty, "empty calldata did not revert");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function test_noOtherPrivilegedEntryPointExists() public {
        string[16] memory signatures = [
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "owner()",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], DEPLOYER, true);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertTrue(!ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY, "supply");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "deployer balance");
    }

    function test_deployerHasNoPowerOverAHolder() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1e18);
        // The deployer cannot pull from a holder without an allowance...
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, DEPLOYER, uint256(0), uint256(1))
        );
        vm.prank(DEPLOYER);
        token.transferFrom(ALICE, DEPLOYER, 1);
        // ...and the holder can still move everything afterwards.
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1e18), "holder cannot transfer");
        assertEq(token.balanceOf(BOB), 1e18, "bob");
        assertEq(token.balanceOf(ALICE), 0, "alice");
    }

    // ---------------------------------------------------------------- transfer boundaries

    function test_transferWholeSupplyThenNothingIsLeft() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY), "whole-supply transfer failed");
        assertEq(token.balanceOf(ALICE), SUPPLY, "alice");
        assertEq(token.balanceOf(DEPLOYER), 0, "deployer");
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, DEPLOYER, uint256(0), uint256(1))
        );
        vm.prank(DEPLOYER);
        token.transfer(BOB, 1);
    }

    function test_transferOneWeiTwice() public {
        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, 1);
        token.transfer(ALICE, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 2, "two one-wei transfers");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 2, "deployer");
    }

    function test_revertWhen_transferSupplyPlusOne() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_revertWhen_transferMaxUint() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, MAX);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "a reverted transfer moved tokens");
    }

    function test_revertWhen_selfTransferExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, ALICE, uint256(0), uint256(1)));
        vm.prank(ALICE);
        token.transfer(ALICE, 1);
    }

    function test_revertWhen_transferFromAddressZeroViaPrank() public {
        // A transaction from the zero address cannot happen on chain, but the code has the branch:
        // it must refuse, with InvalidSender, and never hand out tokens the zero address has not got.
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function test_revertWhen_transferZeroAmountToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 0);
    }

    function test_revertWhen_transferToZeroAddressFromEmptyAccount() public {
        // The receiver check precedes the balance check: the error names the receiver.
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 1);
    }

    function test_balanceOfZeroAddressStaysZero() public {
        assertEq(token.balanceOf(address(0)), 0, "zero address funded at deploy");
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 1);
        assertEq(token.balanceOf(address(0)), 0, "zero address funded by transferFrom");
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX, "a reverted transferFrom changed the allowance");
    }

    function test_transferToTokenItselfIsAllowedAndStuck() public {
        // Nothing exempts or forbids the token's own address; what lands there has no way out,
        // but it is still counted in the supply.
        vm.prank(DEPLOYER);
        token.transfer(address(token), 5);
        assertEq(token.balanceOf(address(token)), 5, "token balance");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    // ---------------------------------------------------------------- allowance boundaries

    function test_revertWhen_ownerUsesTransferFromOnItselfWithoutSelfAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, DEPLOYER, uint256(0), uint256(1))
        );
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_selfAllowanceIsSpentLikeAnyOther() public {
        vm.startPrank(DEPLOYER);
        token.approve(DEPLOYER, 10);
        token.transferFrom(DEPLOYER, ALICE, 4);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 6, "self allowance");
        assertEq(token.balanceOf(ALICE), 4, "alice");
    }

    function test_transferFromZeroAmountNeedsNoAllowanceAndChangesNothing() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 0), "zero transferFrom failed");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "allowance");
        assertEq(token.balanceOf(ALICE), 0, "alice");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "deployer");
    }

    function test_revertWhen_transferFromTheZeroAddress() public {
        // The allowance check passes for amount zero, so the sender check is what must stop it.
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);
    }

    function test_allowanceExactlyEqualToAmountDropsToZeroAndStops() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 7);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 7);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "allowance not exhausted");
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_allowanceOneBelowMaxIsFiniteAndDecreases() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX - 1);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX - 2, "max-1 treated as infinite");
    }

    function test_infiniteAllowanceStillBoundedByBalance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, SUPPLY + 1);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY, "alice");
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX, "infinite allowance changed");
    }

    function test_revertWhen_transferFromExceedsAllowanceByOne() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, SUPPLY, SUPPLY + 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, SUPPLY + 1);
    }

    function test_allowanceCheckPrecedesBalanceCheck() public {
        // ALICE holds nothing and granted nothing: the allowance error is what comes out.
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_revertedTransferFromLeavesAllowanceIntact() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, ALICE, uint256(0), uint256(50)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 50);
        assertEq(token.allowance(ALICE, SPENDER), 100, "allowance consumed by a failed transfer");
    }

    function test_approveZeroClearsAndApproveIsIdempotent() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 5);
        token.approve(SPENDER, 5);
        assertEq(token.allowance(DEPLOYER, SPENDER), 5, "repeated approve changed the value");
        token.approve(SPENDER, 0);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "approve(0) did not clear");
        vm.expectRevert(
            abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_approveDoesNotNeedABalance() public {
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, MAX), "approve failed");
        assertEq(token.allowance(ALICE, SPENDER), MAX, "allowance");
        assertEq(token.balanceOf(ALICE), 0, "approve created tokens");
    }

    function test_allowancesAreDirectional() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10);
        assertEq(token.allowance(SPENDER, DEPLOYER), 0, "allowance leaked backwards");
        assertEq(token.allowance(DEPLOYER, ALICE), 0, "allowance leaked to another spender");
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, ALICE, uint256(0), uint256(1)));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_revertWhen_approveZeroSpenderForZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 0);
    }

    function test_revertWhen_approverIsZeroAddressViaPrank() public {
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(SPENDER, 1);
    }

    // ---------------------------------------------------------------- events

    function test_transferFromEmitsOneTransferNamingOwnerNotSpender() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted a different number of logs");
        assertEq(logs[0].emitter, address(token), "emitter");
        assertEq(logs[0].topics[0], TRANSFER_TOPIC, "not a Transfer");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(DEPLOYER))), "from must be the owner");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(BOB))), "to");
        assertEq(abi.decode(logs[0].data, (uint256)), 3, "value");
    }

    function test_approveEmitsApprovalWithTheNewValueOnly() public {
        vm.recordLogs();
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 10);
        token.approve(SPENDER, 2);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "two approves must emit two Approval logs");
        assertEq(logs[1].topics[0], APPROVAL_TOPIC, "not an Approval");
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(DEPLOYER))), "owner");
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(SPENDER))), "spender");
        assertEq(abi.decode(logs[1].data, (uint256)), 2, "the second Approval must carry 2, not a delta");
    }

    function test_zeroTransferStillEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        token.transfer(BOB, 0);
    }

    // ---------------------------------------------------------------- fuzz: arithmetic at its edges

    function testFuzz_transferBetweenAnyTwoHoldersConservesTheirSum(uint256 funded, uint256 amount, uint256 toSeed)
        public
    {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        address to = toSeed % 2 == 0 ? BOB : ALICE; // ALICE is sometimes also the sender: self-transfer
        vm.prank(DEPLOYER);
        token.transfer(ALICE, funded);
        uint256 sumBefore = token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEPLOYER);
        vm.prank(ALICE);
        assertTrue(token.transfer(to, amount), "returned false");
        uint256 sumAfter = token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEPLOYER);
        assertEq(sumAfter, sumBefore, "tokens created or destroyed");
        assertEq(sumAfter, SUPPLY, "sum of holders differs from supply");
        if (to == ALICE) {
            assertEq(token.balanceOf(ALICE), funded, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(ALICE), funded - amount, "sender");
            assertEq(token.balanceOf(BOB), amount, "receiver");
        }
    }

    function testFuzz_selfTransferNeverChangesBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "self-transfer changed the balance");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    function testFuzz_revertWhen_emptyAccountSendsAnythingPositive(address sender, uint256 amount) public {
        amount = bound(amount, 1, MAX);
        if (sender == DEPLOYER) sender = ALICE;
        if (sender == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(BloxToken.InvalidSender.selector, address(0)));
        } else {
            vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, sender, uint256(0), amount));
        }
        vm.prank(sender);
        token.transfer(BOB, amount);
    }

    function testFuzz_revertWhen_transferFromAboveAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, MAX - 2); // MAX itself is infinite; MAX-1 leaves room for amount
        amount = bound(amount, allowed + 1, MAX);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.expectRevert(abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, allowed, amount));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), allowed, "allowance changed by a reverted call");
        assertEq(token.balanceOf(ALICE), 0, "tokens moved despite the revert");
    }

    function testFuzz_approveStoresExactlyWhatWasGiven(address owner, address spender, uint256 value) public {
        if (owner == address(0)) owner = ALICE;
        if (spender == address(0)) spender = SPENDER;
        vm.prank(owner);
        assertTrue(token.approve(spender, value), "approve failed");
        assertEq(token.allowance(owner, spender), value, "allowance stored differently");
        if (owner != spender) assertEq(token.allowance(spender, owner), 0, "reverse allowance");
    }

    function testFuzz_infiniteAllowanceSurvivesAnySpend(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX, "infinite allowance decreased");
        assertEq(token.balanceOf(ALICE), amount, "alice");
    }

    function testFuzz_finiteAllowanceSpentInTwoSteps(uint256 allowed, uint256 first, uint256 second) public {
        allowed = bound(allowed, 0, SUPPLY);
        first = bound(first, 0, allowed);
        second = bound(second, 0, allowed - first);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.startPrank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, first);
        token.transferFrom(DEPLOYER, BOB, second);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - first - second, "allowance");
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), first + second, "receivers");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - first - second, "owner");
        if (allowed - first - second == 0 && allowed < MAX) {
            vm.expectRevert(
                abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, SPENDER, uint256(0), uint256(1))
            );
            vm.prank(SPENDER);
            token.transferFrom(DEPLOYER, ALICE, 1);
        }
    }

    function testFuzz_noBalanceEverExceedsSupply(address to, uint256 amount) public {
        if (to == address(0) || to == DEPLOYER) to = BOB;
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
        assertLe(token.balanceOf(to), SUPPLY, "receiver above supply");
        assertLe(token.balanceOf(DEPLOYER), SUPPLY, "deployer above supply");
        assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), SUPPLY, "conservation");
    }
}
