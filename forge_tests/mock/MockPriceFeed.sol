// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import /* {*} from */ "../helpers/TestBaseWorkflow.sol";

contract MockPriceFeed is IJBPriceFeed {
    uint256 public fakePrice;
    uint256 public fakeDecimals;

    constructor(uint256 _fakePrice, uint256 _fakeDecimals) {
        fakePrice = _fakePrice;
        fakeDecimals = _fakeDecimals;
    }

    function currentPrice(uint256 _decimals) external view override returns (uint256 _quote) {
        if (_decimals == fakeDecimals) return fakePrice;
        else if (_decimals > fakeDecimals) return fakePrice * 10**(_decimals - fakeDecimals);
        else return fakePrice / 10**(fakeDecimals - _decimals);
    }
}