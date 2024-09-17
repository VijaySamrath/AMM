
const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("DeploymentModule", (m) => {
  const mockDIAOracle2 = m.contract("MockDIAOracle2", [100]);

  const mockToken2 = m.contract("MockToken2", ["MyToken", "MTK", 10000000]);


  const adaptiveLiquidityAMM = m.contract("AdaptiveLiquidityAMM", [
    mockToken2,
    mockToken2,
    mockDIAOracle2,
    mockDIAOracle2
  ]);

 

  return { mockDIAOracle2, mockToken2, adaptiveLiquidityAMM };
});
