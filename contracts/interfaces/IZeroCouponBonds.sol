// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {CoreTypes} from "../libraries/CoreTypes.sol";

interface IZeroCouponBonds {
    function bondInfo() external view returns(CoreTypes.BondInfo memory);
    function interestToken() external view returns (address);
    function interestAmount() external view returns (uint256);
}
