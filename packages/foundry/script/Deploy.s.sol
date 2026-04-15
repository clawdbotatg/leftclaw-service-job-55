// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { BurnGrid } from "../contracts/BurnGrid.sol";

contract DeployScript is ScaffoldETHDeploy {
    address constant CLIENT = 0x7E6Db18aea6b54109f4E5F34242d4A8786E0C471;
    address constant CLAWD_TOKEN = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;

    function run() external ScaffoldEthDeployerRunner {
        BurnGrid burnGrid = new BurnGrid(CLAWD_TOKEN, CLIENT);

        deployments.push(Deployment({ name: "BurnGrid", addr: address(burnGrid) }));

        console.log("BurnGrid deployed at:", address(burnGrid));
        console.log("Owner set to:", CLIENT);
    }
}
