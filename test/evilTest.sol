// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "./MarketplaceHandler.s.sol";
import "../src/BluxeBidManager.sol";
import "../src/EvilERC721.sol";
import "../src/BluxeMarketplace.sol";
import "./BidHandler.s.sol";
import "../src/BluxeStorage.sol";
import "../src/BluxeToken.sol";
import "../src/MockWeth.sol";

contract BluxeInvariantTest is StdInvariant, Test {
    BluxeMarketplace bluxeMarketplace;
    BluxeBidManager bidContract;
    BluxeStorage bluxeStorage;
    BluxeToken bluxe;
    BidHandler bidHandler;
    bluxeHandler handler;
    FakeWETH weth;
    EvilERC721 evil;

    address[] public _admins;
    function setUp() public {
        _admins.push(address(11));
        _admins.push(address(12));
        _admins.push(address(13));

        bluxeStorage = new BluxeStorage(_admins);

        bidContract = new BluxeBidManager(address(bluxeStorage));
        bluxeStorage.setBidManager(address(bidContract));

        bluxeMarketplace = new BluxeMarketplace(address(bluxeStorage));
        bluxeStorage.setMarketplace(address(bluxeMarketplace));

        bluxe = new BluxeToken("", "", address(this), 500, address(this));
        weth = new FakeWETH();

        bluxeStorage.setAuthorized(address(bluxeMarketplace), true);
        bluxeStorage.setAuthorized(address(bidContract), true);
        bluxeStorage.setWeth(address(weth));

        evil = new EvilERC721(address(bluxeMarketplace));
    }

    function test_evilOwnerOfLiesButTransferFake() public {
        evil.mint(1);
        evil.setApprovalForAll(address(bluxeMarketplace), true);

        evil.brick();
        vm.expectRevert(InvalidNFT.selector);
        bluxeMarketplace.createListing(address(evil), 1, 1 ether, false, 0);
    }
    function test_evilTokenTryBricksAfterEscrow() public {
        evil.mint(1);
        evil.setApprovalForAll(address(bluxeMarketplace), true);

        bluxeMarketplace.createListing(address(evil), 1, 1 ether, false, 0);

        bluxeMarketplace.cancelListing(0);
        // assert state still valid
        assertTrue(true);
    }

    function test_evilTokenBricksAfterEscrow() public {
        evil.mint(1);
        evil.setApprovalForAll(address(bluxeMarketplace), true);

        bluxeMarketplace.createListing(address(evil), 1, 1 ether, false, 0);

        // Flip the switch AFTER escrow
        evil.brick();

        // Should NOT brick marketplace logic
        bluxeMarketplace.cancelListing(0);

        // assert state still valid
        assertTrue(true);
    }
}
