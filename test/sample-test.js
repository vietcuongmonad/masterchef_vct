const { expect } = require("chai");
const { ethers } = require("hardhat");

const web3js = require('web3')
//const toWei = web3js.utils.toWei
const toWei = (x) => x

let alice, bob, carol, dev, minter;
before("provider & account settings", async() => {
    [alice, bob, carol, dev, minter] = await ethers.getSigners();
})

let VCToken, MasterChefFactory, MockERC20Factory;
before("fetch contract factories", async() => {
    VCToken = await ethers.getContractFactory('VCT')
    MasterChefFactory = await ethers.getContractFactory('MasterChef')
    MockERC20Factory = await ethers.getContractFactory('MockERC20')
})

let vct, masterchef, lp1, lp2, lp3;
beforeEach('deploy contracts', async() => {
    vct = await VCToken.connect(minter).deploy()
    await vct.deployed()

    // 10 vctPerBlock, startBlock = 1, bonusEndBlock = 100
    masterchef = await MasterChefFactory.connect(minter).deploy(vct.address, dev.address, 10, 1, 1000)
    await masterchef.deployed()

    await vct.connect(minter).transferOwnership(masterchef.address)

    let tmp = toWei('100000')
    lp0 = await MockERC20Factory.connect(minter).deploy('LPToken', 'LP0', tmp)
    await lp0.deployed()
    lp1 = await MockERC20Factory.connect(minter).deploy('LPToken', 'LP1', tmp)
    await lp1.deployed()
    lp2 = await MockERC20Factory.connect(minter).deploy('LPToken', 'LP2', tmp)
    await lp2.deployed()

    tmp = toWei('2000')
    await lp0.connect(minter).transfer(alice.address, tmp);
    await lp1.connect(minter).transfer(alice.address, tmp);
    await lp2.connect(minter).transfer(alice.address, tmp);
})

describe('check add liquidity provider', () => {
    it('testing', async () => {
        await masterchef.connect(minter).add('2000', lp0.address, true)
        await masterchef.connect(minter).add('1000', lp1.address, true)
        await masterchef.connect(minter).add('500', lp2.address, true)

        expect((await masterchef.poolLength()).toString()).to.equal('3')

        await lp0.connect(alice).approve(masterchef.address, toWei('100'))
        await masterchef.connect(alice).deposit(0, toWei('20'))
        await masterchef.connect(alice).deposit(0, toWei('10'))
        expect(
            (await lp0.balanceOf(alice.address)).toString()
        ).to.equal(toWei('1970'))

        /* * In this moment, Alice receive vct before update user.amount 20 -> 30
        *   user.amount = 20
        *   pool.accVCTPerShare = 2
        *   user.rewardDebt = 0
        *  */
        expect(
            (await vct.balanceOf(alice.address)).toString()
        ).to.equal('40')

        // VCTReward = 57, dev receive /=10
        expect(
            (await vct.balanceOf(dev.address)).toString()
        ).to.equal('5')

        await masterchef.connect(alice).withdraw(0, '10')

        expect(
            (await vct.balanceOf(alice.address)).toString()
        ).to.equal('70')

        expect(
            (await lp0.balanceOf(alice.address)).toString()
        ).to.equal(toWei('1980'))

        expect(
            (await vct.balanceOf(dev.address)).toString()
        ).to.equal('10')
    })
})

