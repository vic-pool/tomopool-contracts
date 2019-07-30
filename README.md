# TomoPool Protocol

TomoPool is a decentralized staking service protocol running on the TomoChain blockchain. 
It aims for:

* **Maximize TOMO stakers rewards** compared to the TomoChain standard staking based on TomoMaster.
* **Maximize the decentralization** in masternode-based governance system of TomoChain by giving every staker the right to vote for the masternode decision.

## What's the problem?

In TomoChain's standard staking system, masternodes have an interest of **25\% - 30\%** while 
stakers' interest is only about **6\% - 8\%** or worse, depending on which masternodes the stakers vote for.

Some masternode owners even hire some technical experts and pay him a certain amount of their masternode rewards 
in order to operate the masternode server.
There is nothing wrong with it because technical operations should be carried out by technical experts
in order to secure the network. 
However, this results in **inequality in the benefits** between masternode owners and voters:

Furthermore, the growth of staking service that provides significant moneytary benefices 
attracts several exchanges to run multiple masternodes on TomoChain.
On the one hand, this is a good signal because it shows that TomoChain is gaining its traction
and attention from different parties. 
On the other hand, the power of exchanges that runs many masternodes would centralize TomoChain
that was designed to be secure and decentralized.

* Voters deposit TOMO to get an annual interest of 6-8\%.
* Contrarily, masternode owners have an annual interest of about 25\%, 
after paying about 5\% their profit for a technical expert for masternode operations.
* Masternodes have **the entire right to resign and shut down the node**, leaving stakers **losing 
their daily rewards** if not unvoting in the mean time.
* Many stakers that **do not have enough 50k TOMO** must vote for some masternodes to get
a **lower reward** than the masternode owners.

## Our vision to a more equality system and a more decentralized system

We think that, both masternode owners and stakers have been actively staking into TomoChain
to secure the network, they should get the same annual interest and should be able to participate
to the resigning decision of the node.

We envision that each masternode in TomoChain should be a Decentralized Autonomous System (DAO)
where every staker has their own words in deciding the masternode governance.
Furthermore, being DAO-driven masternodes would push the the decentralization level of TomoChain 
to another level. 

## Our solution: The TomoPool protocol

TomoPool is a decentralized staking protocol running on the TomoChain blockchain in order
to realize our vision.
A masternode owner in TomoPool is a pool not owned by some one with 50k TOMO and a private key, but it is
owned by all stakers staking into the pool.
Concretely, for each pool masternode, a smart contract is deployed on TomoChain.
Every staker can stake TOMO into the pool contract, which will apply to become a TomoChain candidate
if the total stake of the pool is greater than 50k.
The pool contract applies to TomoMaster by calling the function `propose` of TomoMaster contract.

Every unstake (unvote) and vote is all executed through the pool contract which then calls the TomoMaster contract.

### Reward distribution
There is no masternode owner in TomoPool protocol.
All stakers are called `stakers` and have the same annual staking interest, which is around 10.5\%.
Rewards are first received 

### Masternode operator
Any technical expert can join and operate the masternode server to get a percentage of the profits of the DAO masternode.
We will initially provide such service. 
However, as the DAO masternode is driven by stakers, the decision making is truly in the hands of the stakers. 

### Compared to TomoMaster staking
Compared to the standard staking using TomoMaster, TomoPool has the following benefits:

* TomoPool provides around 10.5\% annual interest for stakers instead of around 7\% as in TomoMaster
* Every staker joining the same pool will have the same annual interest, no distinction between who is 
masternode owner and who are stakers. 
* Each masternode will run as a DAO. Every staker has the right to vote for resigning the mastenode. The resigning decision is only made
if 66\% of the stake of the pool approves for Resign.
* TomoPool is decentralized and no one is controlling the funds.

  
 
