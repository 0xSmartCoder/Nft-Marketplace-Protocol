//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

contract EvilNFT is ERC721, IERC2981 {
    constructor() ERC721("Evil", "EVL") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function royaltyInfo(uint256, uint256 salePrice) external pure returns (address, uint256) {
        return (address(0xBEEF), salePrice * 5); // 500% royalty
    }
}
