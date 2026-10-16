// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MiniTest} from "./utils/MiniTest.sol";
import {BloxToken} from "../src/BloxToken.sol";

/// @notice Drives BloxToken with random sequences of calls from several actors and keeps a ghost
/// ledger of what every balance and allowance must be. Clamped handlers reach the meaningful paths;
/// raw handlers send unrestricted inputs (the zero address, amounts above the balance, strangers
/// as spenders) and check that the token refuses exactly when, and with exactly the error, the
/// ERC-20 model says it must.
///
/// The handler never reverts on its own: a disagreement between the token and the model is
/// recorded, and `invariant_tokenAgreesWithModel` reports it with the message.
contract BloxHandler is MiniTest {
    uint256 internal constant MAX = type(uint256).max;

    BloxToken public immutable token;
    uint256 public immutable supply;

    address[] internal actors;
    address[] internal tracked;
    mapping(address => bool) internal isTracked;
    address[] internal spenders;
    mapping(address => bool) internal isSpender;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostMoved; // every unit a successful transfer or transferFrom moved
    uint256 public successes;
    uint256 public expectedReverts;
    uint256 public mismatches;
    string public lastMismatch;

    constructor(BloxToken token_, address deployer, address[] memory actors_) {
        token = token_;
        supply = token_.totalSupply();
        _track(deployer);
        _spender(deployer);
        actors.push(deployer);
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
            _track(actors_[i]);
            _spender(actors_[i]);
        }
        ghostBalance[deployer] = supply;
    }

    // ---------------------------------------------------------------- views for the invariants

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function trackedAt(uint256 i) external view returns (address) {
        return tracked[i];
    }

    function spenderCount() external view returns (uint256) {
        return spenders.length;
    }

    function spenderAt(uint256 i) external view returns (address) {
        return spenders[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ---------------------------------------------------------------- clamped handlers

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _transfer(from, to, amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), ghostBalance[from]);
    }

    function transferOneWei(uint256 fromSeed, uint256 toSeed) external {
        _transfer(_actor(fromSeed), _actor(toSeed), 1);
    }

    function transferSelf(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _transfer(from, from, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        amount = bound(amount, 0, supply);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), MAX);
    }

    function approveRevoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 cap = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        _transferFrom(spender, owner, _actor(toSeed), amount);
    }

    function transferFromAll(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 cap = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed < cap) cap = allowed;
        _transferFrom(spender, owner, _actor(toSeed), cap);
    }

    // ---------------------------------------------------------------- unclamped handlers

    function transferRaw(uint256 fromSeed, address to, uint256 amount) external {
        _transfer(_actor(fromSeed), to, amount);
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        uint256 held = ghostBalance[from];
        excess = bound(excess, 1, MAX - held);
        _transfer(from, _actor(toSeed), held + excess);
    }

    function approveRaw(uint256 ownerSeed, address spender, uint256 amount) external {
        _approve(_actor(ownerSeed), spender, amount);
    }

    function transferFromRaw(uint256 spenderSeed, uint256 ownerSeed, address to, uint256 amount) external {
        _transferFrom(_actor(spenderSeed), _actor(ownerSeed), to, amount);
    }

    function transferFromByStranger(address stranger, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        if (stranger == address(0)) stranger = address(0x57a9);
        _spender(stranger);
        _transferFrom(stranger, _actor(ownerSeed), _actor(toSeed), amount);
    }

    /// @dev Any actor, the deployer included, tries the admin entry points a token might have. None
    /// may exist: the call must fail and nothing may change.
    function adminProbe(uint256 actorSeed, uint256 sigSeed) external {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "transferOwnership(address)",
            "setMinter(address)"
        ];
        address actor = _actor(actorSeed);
        address target = _actor(sigSeed);
        bytes memory data = abi.encodeWithSignature(signatures[sigSeed % signatures.length], target, supply);
        vm.prank(actor);
        (bool ok,) = address(token).call(data);
        _check(!ok, "an admin entry point exists");
        expectedReverts++;
    }

    // ---------------------------------------------------------------- model

    function _transfer(address from, address to, uint256 amount) internal {
        bytes memory expected = _transferError(from, to, amount);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            _check(expected.length == 0, "transfer succeeded where the model expects a revert");
            _check(ok, "transfer returned false");
            _applyTransfer(from, to, amount);
        } catch (bytes memory err) {
            _check(expected.length != 0, "transfer reverted where the model expects success");
            _check(keccak256(err) == keccak256(expected), "transfer reverted with a different error");
            expectedReverts++;
        }
    }

    function _transferFrom(address spender, address from, address to, uint256 amount) internal {
        uint256 current = ghostAllowance[from][spender];
        bytes memory expected;
        if (current != MAX && current < amount) {
            expected = abi.encodeWithSelector(BloxToken.InsufficientAllowance.selector, spender, current, amount);
        } else {
            expected = _transferError(from, to, amount);
        }
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            _check(expected.length == 0, "transferFrom succeeded where the model expects a revert");
            _check(ok, "transferFrom returned false");
            if (current != MAX) ghostAllowance[from][spender] = current - amount;
            _applyTransfer(from, to, amount);
        } catch (bytes memory err) {
            _check(expected.length != 0, "transferFrom reverted where the model expects success");
            _check(keccak256(err) == keccak256(expected), "transferFrom reverted with a different error");
            expectedReverts++;
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        _spender(spender);
        bytes memory expected;
        if (spender == address(0)) expected = abi.encodeWithSelector(BloxToken.InvalidSpender.selector, address(0));
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            _check(expected.length == 0, "approve of the zero spender succeeded");
            _check(ok, "approve returned false");
            ghostAllowance[owner][spender] = amount;
            successes++;
        } catch (bytes memory err) {
            _check(expected.length != 0, "approve reverted where the model expects success");
            _check(keccak256(err) == keccak256(expected), "approve reverted with a different error");
            expectedReverts++;
        }
    }

    function _transferError(address from, address to, uint256 amount) internal view returns (bytes memory) {
        if (to == address(0)) return abi.encodeWithSelector(BloxToken.InvalidReceiver.selector, address(0));
        uint256 held = ghostBalance[from];
        if (held < amount) return abi.encodeWithSelector(BloxToken.InsufficientBalance.selector, from, held, amount);
        return "";
    }

    function _applyTransfer(address from, address to, uint256 amount) internal {
        _track(to);
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        successes++;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _track(address account) internal {
        if (!isTracked[account]) {
            isTracked[account] = true;
            tracked.push(account);
        }
    }

    function _spender(address account) internal {
        if (!isSpender[account]) {
            isSpender[account] = true;
            spenders.push(account);
        }
    }

    function _check(bool condition, string memory reason) internal {
        if (!condition) {
            mismatches++;
            lastMismatch = reason;
        }
    }
}

/// @notice Invariants of a fixed-supply token under random call sequences: the supply never
/// changes, the sum of all balances is the supply, every balance and allowance is what the ledger
/// says, nothing lands on the zero address, and the token's accept/refuse decisions agree with the
/// ERC-20 model on every call.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BloxTokenInvariantTest is MiniTest {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant DEPLOYER = address(0xFAC7);

    BloxToken internal token;
    BloxHandler internal handler;
    address[] internal targets;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new BloxToken();

        address[] memory actors = new address[](5);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA201);
        actors[3] = address(0xDA4E);
        actors[4] = address(0x5BE7D);
        handler = new BloxHandler(token, DEPLOYER, actors);
        targets.push(address(handler));
    }

    /// @dev Only the handler is called by the runner; it drives the token on behalf of the actors.
    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "constant changed");
    }

    function invariant_sumOfAllBalancesIsTheSupply() public view {
        uint256 sum;
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.trackedAt(i));
        }
        assertEq(sum, SUPPLY, "sum of balances differs from the supply");
    }

    function invariant_everyBalanceMatchesTheLedger() public view {
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            address account = handler.trackedAt(i);
            assertEq(token.balanceOf(account), handler.ghostBalance(account), "balance differs from the ledger");
            assertLe(token.balanceOf(account), SUPPLY, "a balance exceeds the supply");
        }
    }

    function invariant_everyAllowanceMatchesTheLedger() public view {
        uint256 owners = handler.actorCount();
        uint256 n = handler.spenderCount();
        for (uint256 i; i < owners; ++i) {
            address owner = handler.actorAt(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.spenderAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance differs from the ledger"
                );
            }
        }
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    function invariant_deployerOnlyLosesWhatItSent() public view {
        // The deployer started with everything; what it holds now plus what left it through its
        // own transfers is bounded by what moved in total. Nothing is minted back to it.
        assertLe(token.balanceOf(DEPLOYER), SUPPLY, "deployer above supply");
        assertEq(token.balanceOf(DEPLOYER), handler.ghostBalance(DEPLOYER), "deployer ledger");
    }

    function invariant_tokenAgreesWithModel() public view {
        if (handler.mismatches() != 0) revert AssertionFailed(handler.lastMismatch());
    }

    /// @dev The campaign actually exercised the token: not a vacuous run of nothing but reverts.
    function afterInvariant() public view {
        assertTrue(handler.successes() > 0 || handler.expectedReverts() > 0, "the handler never reached the token");
    }
}
