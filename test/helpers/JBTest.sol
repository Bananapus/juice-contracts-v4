// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "lib/forge-std/src/Test.sol";

contract JBTest is Test {
    function mockExpect(address _where, bytes memory _encodedCall, bytes memory _returns) public {
        vm.mockCall(_where, _encodedCall, _returns);
        vm.expectCall(_where, _encodedCall);
    }
}
