Aura Infrastructure Lessons Learnt

DISCLAIMER: INTERNAL USE ONLY - NOT TO BE SHARED WITH CUSTOMERS DIRECTLY

Overview

Aura is using kubernetes as its container orchestration. This means we separate between the configuration of vCPUs, Memory and Storage requirements and the provisioned infrastructure. As a result the same Database deployment can perform differently on different generations of infrastructure. Largely our goal is to always be able to run our database deployments on as wide a variety of infrastructure as possible. 

If the Database deployment fits in size on an instance type and that instance type provides a “good enough cpu” the instance selection becomes a cost optimization exercise. Balanced, Memory Optimized or CPU Optimized is a cost/performance optimization question. Generally Databases are more memory intensive workloads and memory is generally cheaper than CPU. But the best selection is always the one that creates the least amount of waste. Combining this with instance availability and it becomes a hard question to answer, what is the best option. Hence we are moving towards using AWS Karpenter and Azure Karpenter which helps optimize instance selection. 

Currently we only support x86 architecture and not ARM CPUs in Aura. Neo4j itself has been benchmarked and tested on ARM and runs really well on it, but for Aura it's a tool chain migration that we have not been able to get prioritized just yet. 

For storage we currently only use NVMe storage for load backup and recovery scenarios, where we create ephemeral instances for those jobs. We are currently working on a “BC Metal” offering which will run on NVMe storage which we hope to be able to start rolling out by end of Q1 or early Q2. This offering will roll out AWS first, followed by GCP and then we need to decide if we offer it on Azure or not. We currently have the NVMe based load, backup and recovery features disabled on Azure. Everything with Azure is a challenge at this point, especially availability of instance types across regions, more on that below. The extra challenge with NVMe storage for us is the fixed memory to storage rates. With AWS they have the best ratios with the most disc per ram and Azure the least. 

The “BC Metal” project has done some benchmarking on local storage vs attached volumes and depending on use case the performance increases as little as 10% but as much as 10x. For more information about the BC Metal project then please reach out.

Aura Databases range from 1 GB (only in Free) to 512 GB (with up to 1.5 TB coming this quarter). Generally I would agree that the 1-2 GB sizes should not be recommended, especially not the 1GB. So recommending 4GB and up is a good idea.
Azure Challenges
Working with Azure is a huge challenge atm. Not just for us but for our customers as well. Azure has availability issues in 80% of their regions. This means that some or all instance types are restricted to those regions. Restrictions are per sub and highly depend on when the sub was created. To lift restrictions customers must create support cases and request a lift. It can be rejected, partially fulfilled on 1 or 2 AZs or fully fulfilled on all 3 AZs (this is rare and often requires significant escalations).  

As a result we are shifting our approach from strictly 3 AZs and a very select set of instance types to a more “what we can get wherever we can get it” approach. Honestly working with Azure at this point feels very much like a Mad Max movie. 

Here are the instances we are using atm and the count. Still not a large spread but as we roll out Karpenter in Azure the spread will grow and more families will be used.


+-----------------------+------------+-----------+
| Family                | Generation | Instances |
+-----------------------+------------+-----------+
| D-Series (General)    | v6         | 23        |
|                       | v5         | 531       |
|                       | v4         | 410       |
+-----------------------+------------+-----------+
| Da-Series (AMD GP)    | v5         | 4         |
+-----------------------+------------+-----------+
| E-Series (Mem Opt)    | v6         | 22        |
+-----------------------+------------+-----------+
| TOTAL                 |            | 990       |
+-----------------------+------------+-----------+

For storage we use Azure Premium SSD v2 for all database deployments. Compared to instance availability storage is not an issue for us, at least not a prioritized one.

AWS Challenges
AWS generally works much much better. The availability is good when it comes to the standard instance types. Challenges only arise when we get to really large instances like 1.5 TB memory or GPU based instances. Then availability becomes more of an issue.

AWS also has the best availability on NVMe storage with lots of instance types with high RAM to Disc ratios. 

Here is our AWS usage by family and generation. We do not recommend using generation 5 as the performance drop is quite noticeable and not worth the price/performance hit. Generation 7 and 8 are not widely enough available to be the general recommendation.

We have some optimizations on how we provision CPU that will shift us more towards the memory optimized side of things. So I'm expecting a more even distribution over the three families over time.


+-----------------------+------------+-----------+
| Family                | Generation | Instances |
+-----------------------+------------+-----------+
| M-Series (General)    | 6th (AMD)  | 1,761     |
|                       | 5th (AMD)  | 29        |
+-----------------------+------------+-----------+
| C-Series (Compute)    | 7th (Intel)| 38        |
|                       | 6th (AMD)  | 1,179     |
|                       | 6th (Intel)| 5         |
|                       | 5th (AMD)  | 2         |
+-----------------------+------------+-----------+
| R-Series (Memory Opt) | 6th (AMD)  | 84        |
|                       | 6th (Intel)| 9         |
|                       | 5th (AMD)  | 5         |
+-----------------------+------------+-----------+
| TOTAL                 |            | 3,112     |
+-----------------------+------------+-----------+


AWS EBS Storage is actually the most challenging storage service. Not necessarily due to quality or availability but due to complexity. With EBS GP3 and IO2 you need to provision IOPS, Throughput and Size. Understanding how to best scale storage and how these relate to each other as we scale is hard and time consuming. GCP provides just one knob with IOPs per GB. This is much simpler to get the ball park right, whereas it can't get as optimized as EBS can get. 

IO2 is also ridiculously expensive, so we are trying to stay clear of it as much as possible. While the performance is much higher than GP3 the price performance is painful and one of the reasons we are doing “BC Metal”. To provide the NVMe discs as a high performance option, even though it's more operationally challenging to provide the same level of durability as with EBS.

GCP Challenges
GCP availability is quite good across the board. As with AWS the challenges start to arise as we move to very large instances 1.5TB and GPUs. Those are typically only in 2 AZs and in fewer regions then we support. The challenges we see with GCP are not really on infrastructure, its performance or availability. For us it's more on the service level and the inflexibility of the services, but that is outside the scope of this subject.

Here are our GCP instance types, As with AWS we like AMD on GCP as well. It's a nice cost optimization with minimal performance impact. GCP has few instance types making life easier. We will lean even more towards high memory as our optimizations on CPU provisioning come in. 

+-----------------------+-------------+-----------+
| Family (Optimization) | Generation  | Instances | 
+-----------------------+-------------+-----------+
| N2D (AMD, High-Memory)| 2nd Gen     | 1,109     |
| N2D (AMD, Standard)   | 2nd Gen     | 708       |
+-----------------------+-------------+-----------+
| N2  (Intel, Standard) | 2nd Gen     | 253       |
+-----------------------+-------------+-----------+
| TOTAL                 |             | 2,070     |
+-----------------------+-------------+-----------+



