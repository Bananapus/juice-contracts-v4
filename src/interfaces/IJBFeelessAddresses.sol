// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IJBFeelessAddresses {
    event SetFeelessAddress(address indexed account, bool indexed isFeeless, address caller);

    function isFeelessAddress(address account) external view returns (bool);

    function setFeelessAddress(address account, bool flag) external;
}
