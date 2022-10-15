// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "hardhat/console.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

error RoundAlreadyStarted();
error RoundNotEnded();
error BufferTimeNotEnded();
error InvalidParams();
error PriceTooLow();
error Unauthorized();
error SwapFailed();
error MigrationAlreadyScheduled();
error MigrationNotScheduledYet();

contract CoveredCallVault is ERC4626, Owned, Pausable {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    uint256 public constant migrationDelay = 7 days;

    ERC20 public immutable usdc;
    /// @dev address = 20 bytes, tightly pack next to uint64 to tightly pack for gas savings (stored in one slot)
    address public immutable exchangeAddress;

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice duration in seconds, assets which are not withdrawn from the smart contract roll into the next round
    /// when rollOptionsVault is called
    /// @dev uint64 = 8 bytes; max value 18446744073709551615; enough to store buffer time so we can tightly pack
    uint64 public bufferTime;

    uint256 public limitPrice;
    uint256 public endTime;
    uint256 public startTime;

    uint256 public migrateableAfter;
    address public migrationTarget;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OptionBuy(uint256 amount, uint256 price, uint256 totalUsdc);

    event RolledForward(
        uint256 usdcSwapped,
        uint256 assetBalanceBefore,
        uint256 assetBalanceAfter,
        uint256 startTime,
        uint256 endTime
    );

    event MigrationScheduled(uint256 migrateableAfter, address migrationTarget);
    event MigrationExecuted(address migrationTarget);

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR / INITIALIZE
    //////////////////////////////////////////////////////////////*/

    constructor(
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _exchangeAddress,
        uint64 _bufferTime,
        ERC20 _usdc,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _limitPrice
    ) ERC4626(_asset, _name, _symbol) Owned(msg.sender) {
        exchangeAddress = _exchangeAddress;
        usdc = _usdc;

        startTime = _startTime;
        endTime = _endTime;
        bufferTime = _bufferTime;
        limitPrice = _limitPrice;
    }

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyExchange() {
        if (msg.sender != exchangeAddress) {
            revert Unauthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADE / MIGRATE
    //////////////////////////////////////////////////////////////*/

    function scheduleMigration(address _migrationTarget) external onlyOwner {
        if (migrateableAfter != 0) {
            revert MigrationAlreadyScheduled();
        }
        if (_migrationTarget == address(0)) {
            revert InvalidParams();
        }

        migrateableAfter = block.timestamp + migrationDelay;
        migrationTarget = _migrationTarget;

        emit MigrationScheduled(migrateableAfter, migrationTarget);
    }

    function executeMigration() external onlyOwner {
        if (block.timestamp < migrateableAfter) {
            revert MigrationNotScheduledYet();
        }

        asset.safeTransfer(migrationTarget, asset.balanceOf(address(this)));
        usdc.safeTransfer(migrationTarget, usdc.balanceOf(address(this)));

        delete migrationTarget;
        delete migrateableAfter;

        emit MigrationExecuted(migrationTarget);
    }

    /*//////////////////////////////////////////////////////////////
                                 READ LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function totalUsdc() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function previewRedeemUsdc(uint256 shares) public view returns (uint256) {
        /// @dev logic below mostly taken from solmate/src/mixins/ERC4626.sol (replaced totalAssets() with totalUsdc())

        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalUsdc(), supply);
    }

    /*//////////////////////////////////////////////////////////////
                                 OPTIONS LOGIC
    //////////////////////////////////////////////////////////////*/

    function rollOptionsVault(
        uint256 _startTime,
        uint256 _endTime,
        IUniswapV2Router02 uniV2Router,
        uint256 minSwapAmountOut
    ) external whenNotPaused {
        if (block.timestamp <= endTime + bufferTime) {
            revert BufferTimeNotEnded();
        }

        if (
            _startTime >= _endTime ||
            _startTime < block.timestamp + 1 ||
            minSwapAmountOut == 0 ||
            address(uniV2Router) == address(0)
        ) {
            revert InvalidParams();
        }

        uint256 assetBalanceBefore = totalAssets();
        uint256 usdcSwapped = totalUsdc();

        if (totalUsdc() != 0) {
            // convert all usdc to WETH with univ2 interface
            // only swap needed to roll forward users USDC shares to WETH because overall shares stay the same
            _swapExactTokensForTokensUniV2(
                usdc.balanceOf(address(this)),
                minSwapAmountOut,
                uniV2Router
            );

            if (totalUsdc() != 0) {
                revert SwapFailed();
            }
        }

        startTime = _startTime;
        endTime = _endTime;

        emit RolledForward(
            usdcSwapped,
            assetBalanceBefore,
            asset.balanceOf(address(this)),
            startTime,
            endTime
        );
    }

    /// @notice called by external contract (options exchange) to buy option
    /// @param assetAmount amount of asset to buy options for
    /// @param price price for 1 contract
    ///              e.g. if exchange is buying options on 10 ETH options contracts with a price of 25USDC each, the total cost is 250
    function buyOption(uint256 assetAmount, uint256 price)
        external
        whenNotPaused
        onlyExchange
    {
        if (
            block.timestamp > endTime && block.timestamp < endTime + bufferTime
        ) {
            revert BufferTimeNotEnded();
        }

        if (price < limitPrice) {
            revert PriceTooLow();
        }

        uint256 usdcAmount = assetAmount.mulWadUp(price);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // increase allowance instead of replace
        uint256 newAllowance = usdc.allowance(address(this), msg.sender) +
            assetAmount;

        asset.safeApprove(exchangeAddress, newAllowance);

        emit OptionBuy(assetAmount, price, usdcAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        returns (uint256 shares)
    {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        _deposit(shares, receiver, assets);

        return assets;
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        returns (uint256 assets)
    {
        // No need to check for rounding error, previewMint rounds up.
        assets = previewMint(shares);

        _deposit(shares, receiver, assets);

        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        // No need to check for rounding error, previewWithdraw rounds up.
        shares = previewWithdraw(assets);

        _withdraw(assets, receiver, owner, shares);

        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        _withdraw(assets, receiver, owner, shares);

        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER ONLY LOGIC
    //////////////////////////////////////////////////////////////*/

    function setBufferTime(uint64 _bufferTime) external onlyOwner {
        bufferTime = _bufferTime;
    }

    function setLimitPrice(uint256 _limitPrice) external onlyOwner {
        limitPrice = _limitPrice;
    }

    function emergencyPause() external onlyOwner {
        _pause();
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _deposit(
        uint256 assets,
        address receiver,
        uint256 shares
    ) internal {
        // deposit is only possible before startTime
        if (block.timestamp >= startTime) {
            revert RoundAlreadyStarted();
        }

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function _withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 shares
    ) internal {
        // withdraw is only possible after endTime
        if (block.timestamp <= endTime) {
            revert RoundNotEnded();
        }

        /// @dev logic below mostly taken from solmate/src/mixins/ERC4626.sol (added usdc part)
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assets, shares);

        uint256 usdcAssets = previewRedeemUsdc(shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);

        if (usdcAssets != 0) {
            usdc.safeTransfer(receiver, usdcAssets);
        }
    }

    /**
     *  Execute exact input swap via UniswapV2
     *
     * @param _amountIn     The amount of input token to be spent
     * @param _minAmountOut Minimum amount of output token to receive
     * @param _router       Address of uniV2 router to use
     *
     * @return amountOut    The amount of output token obtained
     */
    function _swapExactTokensForTokensUniV2(
        uint256 _amountIn,
        uint256 _minAmountOut,
        IUniswapV2Router02 _router
    ) internal returns (uint256) {
        usdc.safeApprove(address(_router), _amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(asset);

        uint256[] memory result = _router.swapExactTokensForTokens(
            _amountIn,
            _minAmountOut,
            path,
            address(this),
            block.timestamp
        );

        return result[result.length - 1];
    }
}
