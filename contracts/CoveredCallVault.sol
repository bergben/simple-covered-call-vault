// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {Owned} from "solmate/src/auth/Owned.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

error RoundAlreadyStarted();
error RoundNotEnded();
error BufferTimeNotEnded();
error InvalidParams();
error PriceTooLow();
error Unauthorized();
error SwapFailed();

contract CoveredCallVault is ERC4626Upgradeable, Owned, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20Upgradeable public usdc;
    /// @dev address = 20 bytes, tightly pack next to uint64 to tightly pack for gas savings (stored in one slot)
    address public exchangeAddress;

    /// @notice duration in seconds, assets which are not withdrawn from the smart contract roll into the next round
    /// when rollOptionsVault is called
    /// @dev uint64 = 8 bytes; max value 18446744073709551615; enough to store buffer time so we can tightly pack
    uint64 public bufferTime;

    uint256 public limitPrice;
    uint256 public endTime;
    uint256 public startTime;

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

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR / INITIALIZE
    //////////////////////////////////////////////////////////////*/
    constructor() Owned(msg.sender) {}

    function initialize(
        IERC20Upgradeable _asset,
        string memory _name,
        string memory _symbol,
        address _exchangeAddress,
        uint64 _bufferTime,
        IERC20Upgradeable _usdc,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _limitPrice
    ) external initializer {
        owner = msg.sender;

        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);

        exchangeAddress = _exchangeAddress;
        bufferTime = _bufferTime;
        usdc = _usdc;
        startTime = _startTime;
        endTime = _endTime;
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
                                 READ LOGIC
    //////////////////////////////////////////////////////////////*/
    function totalUsdc() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function previewRedeemUsdc(uint256 shares) public view returns (uint256) {
        /// @dev logic below mostly taken from solmate/src/mixins/ERC4626.sol (replaced totalAssets() with totalUsdc())

        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

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
            IERC20Upgradeable(asset()).balanceOf(address(this)),
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

        IERC20Upgradeable(asset()).safeApprove(exchangeAddress, newAllowance);

        emit OptionBuy(assetAmount, price, usdcAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        returns (uint256)
    {
        require(
            assets <= maxDeposit(receiver),
            "ERC4626: deposit more than max"
        );

        uint256 shares = previewDeposit(assets);

        _depositWithChecks(shares, receiver, assets);

        return shares;
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        returns (uint256)
    {
        require(shares <= maxMint(receiver), "ERC4626: mint more than max");

        uint256 assets = previewMint(shares);
        _depositWithChecks(shares, receiver, assets);

        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        require(
            assets <= maxWithdraw(owner),
            "ERC4626: withdraw more than max"
        );

        uint256 shares = previewWithdraw(assets);
        _withdrawWithChecks(assets, receiver, owner, shares);

        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        uint256 assets = previewRedeem(shares);
        _withdrawWithChecks(assets, receiver, owner, shares);

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

    function _depositWithChecks(
        uint256 assets,
        address receiver,
        uint256 shares
    ) internal {
        // deposit is only possible before startTime
        if (block.timestamp >= startTime) {
            revert RoundAlreadyStarted();
        }

        _deposit(_msgSender(), receiver, assets, shares);
    }

    function _withdrawWithChecks(
        uint256 assets,
        address receiver,
        address owner,
        uint256 shares
    ) internal {
        // withdraw is only possible after endTime
        if (block.timestamp <= endTime) {
            revert RoundNotEnded();
        }

        uint256 usdcAssets = previewRedeemUsdc(shares);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

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
        path[1] = asset();

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
