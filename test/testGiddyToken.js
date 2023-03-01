const { expect } = require("chai");
const { web3, ethers, upgrades } = require("hardhat");
// eslint-disable-next-line node/no-extraneous-require
const ethSigUtil = require("eth-sig-util");

describe("Token contract", function () {
  let giddyToken;
  let owner;
  let addr1;

  it("Deploys and sets correct totalSupply", async function () {
    [owner, addr1] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("GiddyToken");

    giddyToken = await upgrades.deployProxy(Token, [
      "GiddyToken",
      "GDDY",
      "1.0",
    ]);

    await giddyToken.deployed();

    console.log("Contract deployed to: " + giddyToken.address);
    console.log("Total Supply == " + (await giddyToken.totalSupply()));
    console.log("DOMAIN_SEPARATOR: " + (await giddyToken.DOMAIN_SEPARATOR()));
    console.log(
      "APPROVE_WITH_AUTHORIZATION_TYPEHASH: " +
        (await giddyToken.APPROVE_WITH_AUTHORIZATION_TYPEHASH())
    );

    const ownerBalance = await giddyToken.balanceOf(owner.address);
    console.log("OwnerBalance: " + ownerBalance);
    expect(await giddyToken.totalSupply()).to.equal(ownerBalance);
    expect(await giddyToken.name()).to.equal("GiddyToken");
    expect(await giddyToken.symbol()).to.equal("GIDDY");
  });

  it("Can be transferred with normal approvals", async function () {
    await giddyToken.approve(addr1.address, "100000000000", {
      from: owner.address,
    });
    const allowance = await giddyToken.allowance(owner.address, addr1.address);
    console.log("Owner allowance: " + allowance);
    expect(allowance).to.equal(100000000000);

    await giddyToken
      .connect(addr1)
      .transferFrom(owner.address, addr1.address, allowance);

    expect(await giddyToken.balanceOf(addr1.address)).to.equal("100000000000");
    expect(await giddyToken.allowance(owner.address, addr1.address)).to.equal(
      0
    );
  });

  it("Can be transferred with Approval Requests and used only once", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "0",
    };

    const [signature, approvalRequest] = generateSignature(message, giddyToken);

    await giddyToken.approveWithAuthorization(approvalRequest, signature);

    expect(
      await giddyToken.allowance(owner.address, giddyToken.address)
    ).to.equal("100000000000");

    await expect(
      giddyToken.approveWithAuthorization(approvalRequest, signature)
    ).to.be.revertedWith("ApprovalRequest: authorization is already used");
  });

  it("will fail if currentApproval is incorrect", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "10",
    };

    const [signature, approvalRequest] = generateSignature(message, giddyToken);

    await expect(
      giddyToken.approveWithAuthorization(approvalRequest, signature)
    ).to.be.revertedWith("ApprovalRequest: Incorrect approval given");

    expect(
      await giddyToken.allowance(owner.address, giddyToken.address)
    ).to.equal("100000000000");
  });

  it("Can update Approval", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "1000000",
      deadline: (Math.floor(Date.now() / 1000) + 1000).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "100000000000",
    };

    const [signature, approvalRequest] = generateSignature(message, giddyToken);

    await giddyToken.approveWithAuthorization(approvalRequest, signature);

    expect(
      await giddyToken.allowance(owner.address, giddyToken.address)
    ).to.equal("1000000");
  });

  it("will fail if deadline has passed", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) - 500).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "1000000",
    };

    const [signature, approvalRequest] = generateSignature(message, giddyToken);

    await expect(
      giddyToken.approveWithAuthorization(approvalRequest, signature)
    ).to.be.revertedWith("ApprovalRequest: expired");
  });

  it("will fail if ECDSA signature is invalid", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "1000000",
    };

    const [, approvalRequest] = generateSignature(message, giddyToken);

    await expect(
      giddyToken.approveWithAuthorization(
        approvalRequest,
        "0x" + "0".repeat(130)
      )
    ).to.be.revertedWith("ECDSA: invalid signature 'v' value");
  });

  it("will fail if Approval signature is from the wrong address", async function () {
    const message = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: web3.utils.randomHex(32),
      currentApproval: "1000000",
    };

    const [signature, approvalRequest] = generateSignature(
      message,
      giddyToken,
      "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff81"
    );

    await expect(
      giddyToken.approveWithAuthorization(approvalRequest, signature)
    ).to.be.revertedWith("ApprovalRequest: invalid signature");
  });

  it("will fail if nonce is used", async function () {
    const nonce = web3.utils.randomHex(32)

    const message1 = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000000000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: nonce,
      currentApproval: "1000000",
    };

    const message2 = {
      owner: owner.address,
      spender: giddyToken.address,
      value: "100000",
      deadline: (Math.floor(Date.now() / 1000) + 500).toString(),
      nonce: nonce,
      currentApproval: "100000000000",
    };

    const [signature1, approvalRequest1] = generateSignature(message1, giddyToken);

    await giddyToken.approveWithAuthorization(approvalRequest1, signature1);

    const [signature2, approvalRequest2] = generateSignature(message2, giddyToken);

    await expect(
      giddyToken.approveWithAuthorization(approvalRequest2, signature2)
    ).to.be.revertedWith("ApprovalRequest: authorization is already used");
  });
});

function generateSignature(
  message,
  giddyToken,
  pkey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
) {
  const data = {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      ApproveWithAuthorization: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "nonce", type: "bytes32" },
        { name: "currentApproval", type: "uint256" },
      ],
    },
    domain: {
      name: "GiddyToken",
      version: "1.0",
      verifyingContract: giddyToken.address,
      chainId: "31337",
    },
    primaryType: "ApproveWithAuthorization",
    message: message,
  };

  const signature = ethSigUtil.signTypedMessage(Buffer.from(pkey, "hex"), {
    data,
  });

  const approvalRequest = {
    owner: message.owner,
    spender: message.spender,
    value: message.value,
    deadline: message.deadline,
    nonce: message.nonce,
    currentApproval: message.currentApproval,
  };

  return [signature, approvalRequest];
}
