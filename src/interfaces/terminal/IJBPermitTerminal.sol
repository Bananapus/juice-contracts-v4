// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2} from "../../../lib/permit2/src/interfaces/IPermit2.sol";
import {IJBTerminal} from "./IJBTerminal.sol";

interface IJBPermitTerminal is IJBTerminal {
    function PERMIT2() external returns (IPermit2);
}
