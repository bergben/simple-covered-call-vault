import { ethers } from "hardhat";
import { CoveredCallVault__factory, VaultProxy__factory } from "../typechain";

async function main() {
  const vaultFactory = (await ethers.getContractFactory(
    "CoveredCallVault"
  )) as CoveredCallVault__factory;

  const wethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

  let vault = await vaultFactory.deploy();
  // arbitrary values below
  vault.initialize(
    wethAddress,
    "CoveredCallVaultWETH",
    "ccvWETH",
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB11",
    86400,
    usdcAddress,
    100,
    200,
    100
  );

  const proxyFactory = (await ethers.getContractFactory(
    "VaultProxy"
  )) as VaultProxy__factory;

  let contract = await proxyFactory.deploy(
    vault.address,
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB11",
    ""
  );

  console.log(
    `The address the Contract WILL have once mined: ${contract.address}`
  );

  console.log(
    `The transaction that was sent to the network to deploy the Contract: ${contract.deployTransaction.hash}`
  );

  console.log(
    "The contract is NOT deployed yet; we must wait until it is mined..."
  );
  await contract.deployed();
  console.log("Mined!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
