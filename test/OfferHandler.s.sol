//SPDX-License-idendentifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/BluxeBidManager.sol";
import "../src/BluxeMarketplace.sol";
import "../src/BluxeOfferManager.sol";
import "../src/BluxeStorage.sol";
import "../src/BluxeToken.sol";
import "../src/MockWeth.sol";

contract OfferHandler is Test {
    BluxeBidManager bidContract;
    BluxeOfferManager offerContract;
    BluxeMarketplace marketplace;
    BluxeStorage storageContract;
    BluxeToken bluxe;
    FakeWETH weth;

    address[] public offerers;
    uint256 TotalListings = 10;
    uint256 public totalEthDeposited;
    uint256 public totalWethDeposited;

    constructor(
        BluxeBidManager _bidContract,
        BluxeOfferManager _offerContract,
        BluxeMarketplace _marketplace,
        BluxeStorage _storage,
        BluxeToken _bluxe,
        FakeWETH _wethAddress
    ) {
        bidContract = _bidContract;
        offerContract = _offerContract;
        marketplace = _marketplace;
        storageContract = _storage;
        bluxe = _bluxe;
        weth = _wethAddress;

        offerers.push(address(0xA1));
        offerers.push(address(0xA2));
        offerers.push(address(0xA3));
        offerers.push(address(0xA4));
        offerers.push(address(0xA5));

        for (uint i = 0; i < offerers.length; i++) {
            vm.deal(offerers[i], 20 ether);
            weth.mint(offerers[i], 5 ether);
        }
    }

    function _randomofferers(uint256 seed) public view returns (address) {
        return offerers[seed % offerers.length];
    }
    function makeOfferETH(uint256 seed, uint256 amountSeed) public {
        address offerer = _randomofferers(seed);
        uint256 listingId = seed % TotalListings;

        BluxeStorage.Listing memory l = storageContract.getListing(listingId);
        if (!l.active) return;
        if (l.auction) return;
        if (offerer == l.seller) return;

        uint256 amount = bound(amountSeed, 0.5 ether, 2.6 ether);

        vm.prank(offerer);
        offerContract.makeOfferEth(listingId);
    }

    function makeOfferWETH(uint256 seed, uint256 amountSeed) public {
        address offerer = _randomofferers(seed);
        uint256 listingId = seed % TotalListings;

        BluxeStorage.Listing memory l = storageContract.getListing(listingId);
        if (!l.active) return;
        if (l.auction) return;
        if (offerer == l.seller) return;

        uint256 amount = bound(amountSeed, 0.3 ether, 3.6 ether);

        vm.startPrank(offerer);
        weth.approve(address(offerContract), amount);
        offerContract.makeOfferWeth(listingId, amount);
        vm.stopPrank();
    }

    function acceptOffer(uint256 seed) public {
        uint256 listingId = seed % TotalListings;
        BluxeStorage.Listing memory l = storageContract.getListing(listingId);
        address buyer = _randomofferers(seed);

        if (!l.active) return;
        if (l.auction) return;
        marketplace.acceptOffer(buyer, listingId);

        // claim NFT
        BluxeStorage.AcceptedOffer memory a = storageContract.getAcceptedOffer(listingId);
        vm.prank(a.winner);
        marketplace.claimOfferNFT(listingId);
    }
}
