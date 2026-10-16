// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The few Foundry cheatcodes these tests use, declared here so the project needs no
/// vendored test library.
interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function assume(bool condition) external pure;
}

/// @notice Minimal assertion helpers: a failed assertion reverts, which fails the test.
abstract contract MiniTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AssertionFailed(string reason);
    error AssertionEqFailed(string reason, uint256 left, uint256 right);

    function assertEq(uint256 left, uint256 right, string memory reason) internal pure {
        if (left != right) revert AssertionEqFailed(reason, left, right);
    }

    function assertEq(string memory left, string memory right, string memory reason) internal pure {
        if (keccak256(bytes(left)) != keccak256(bytes(right))) revert AssertionFailed(reason);
    }

    function assertTrue(bool condition, string memory reason) internal pure {
        if (!condition) revert AssertionFailed(reason);
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }
}
