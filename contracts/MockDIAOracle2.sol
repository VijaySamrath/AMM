// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockDIAOracle2{
    uint256 private price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getPrice(address) external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }
}