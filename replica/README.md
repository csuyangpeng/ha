# Cluster
redis/mysql/etcd cluster, addons mysqlrouter 
<img width="1986" height="1452" alt="image" src="https://github.com/user-attachments/assets/adb7250c-c32b-4965-b777-e6b8bcfa8a64" />

## How to use the cluster
Prepare 3 or more servers. Clone the repository, use init.sh to init the environment.

## How the check the cluster
cluster.status()  
<img width="651" height="676" alt="image" src="https://github.com/user-attachments/assets/ac3770da-f8e0-4213-a03b-f2031e72f3b5" />  
docker exec redis1 redis-cli -a 'A8K5h7+6!?' --cluster check 10.18.30.11:6379  
<img width="794" height="439" alt="image" src="https://github.com/user-attachments/assets/e1e2f9ad-2aac-46db-a6ff-c35e979b237e" />  
docker exec -it etcd etcdctl   --endpoints=http://10.18.30.11:2379,http://10.18.30.12:2379,http://10.18.30.13:2379   endpoint status --write-out=table  
<img width="1180" height="102" alt="image" src="https://github.com/user-attachments/assets/93080c62-531a-4f88-8177-91865354b8d2" />  

## How to test the HA of the cluster
cluster_check.sh: used to check the health of the cluster.  
cluster_operator.sh: used to test the r/w ops of the cluster.  
cluster_consistency.sh: used to check the consistency of the cluster.  
