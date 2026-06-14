//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BluxeMarketplace.sol";
import "../src/BluxeStorage.sol";
import "../src/BluxeToken.sol";
import "../src/MockWeth.sol";
import "../src/EvilERC721.sol";

contract bluxeHandler is Test {
    BluxeMarketplace marketplace;
    BluxeStorage storageContract;
    BluxeToken bluxe;
    FakeWETH weth;
    // EvilERC721 evil;

    address public seller;
    address public user1;
    address public user2;

    constructor(
        BluxeMarketplace _marketplace,
        BluxeStorage _storage,
        BluxeToken _bluxe,
        FakeWETH _wethAddress
        // EvilERC721 _evilERC721
    ) {
        marketplace = _marketplace;
        storageContract = _storage;
        // EvilERC721 = _evilERC721;
        bluxe = _bluxe;
        weth = _wethAddress;
        seller = address(this);
        user1 = address(0xA1);
        user2 = address(0xB2);

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // get random user
    function _randomUser(uint256 seed) public view returns (address) {
        return seed / 2 == 0 ? user1 : user2;
    }

    // -------- FUNCTIONS --------
    function buy(uint256 seed) public {
        uint256 listingId = seed % 4 /** We have 4 listings */;
        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active) revert();
        if (l.auction) revert();
        address buyer = _randomUser(seed);
        vm.startPrank(buyer);
        marketplace.buyItemWithEth{value: l.price}(listingId);
        vm.stopPrank();
    }

    function evilBuy(uint256 seed) public {
        uint256 listingId = 0;
        BluxeStorage.Listing memory l = storageContract.getListing(0);

        if (!l.active) revert();
        if (l.auction) revert();
        address buyer = _randomUser(seed);
        vm.startPrank(buyer);
        marketplace.buyItemWithEth{value: l.price}(listingId);
        vm.stopPrank();
    }

    function buyViaWETH(uint256 seed) public {
        uint256 listingId = seed % 4 /** We have 4 listings */;
        address buyer = _randomUser(seed);

        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        vm.startPrank(buyer);
        weth.mint(buyer, l.price);
        weth.approve(address(marketplace), l.price);

        marketplace.buyItemWithWeth(listingId);

        vm.stopPrank();
    }

    function cancelListing(uint256 seed) public {
        uint256 listingId = seed % 4 /** We have 4 listings */;

        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active) revert();
        if (msg.sender != l.seller) revert();

        if (!l.active) return;
        vm.startPrank(seller);
        marketplace.cancelListing(listingId);
    }
}
