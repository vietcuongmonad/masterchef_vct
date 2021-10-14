// "SPDX-License-Identifier: UNLICENSED"
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VCT is ERC20("VCToken", "VCT"), Ownable {
    function mint(address to, uint amount) public onlyOwner {
        _mint(to, amount);
    }
}