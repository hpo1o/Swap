// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20FotMock is ERC20 {
    uint8  private _decimals;
    uint256 public feeBps;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 _feeBps
    ) ERC20(name, symbol) {
        _decimals = decimals_;
        feeBps    = _feeBps;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
