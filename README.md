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


# Replica
redis/mysql/etcd replica with keepalived VIP 
<img width="2152" height="1302" alt="image" src="https://github.com/user-attachments/assets/129dc3d5-55ce-4916-a641-f0155158e238" />

## How to check the replica 
On Slave:  
<img width="818" height="38" alt="image" src="https://github.com/user-attachments/assets/3c818881-5577-43ab-8c10-4ca80b9457e8" />  
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G"  
<img width="1681" height="886" alt="image" src="https://github.com/user-attachments/assets/fafdb160-c138-447a-832f-14fd0a8ef72d" /> 
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication 
<img width="1681" height="300" alt="image" src="https://github.com/user-attachments/assets/20f6d60d-c78b-408a-890f-96f017a85f58" /> 
docker exec -i etcd etcdctl --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 endpoint status --write-out=table 
<img width="1681" height="104" alt="image" src="https://github.com/user-attachments/assets/4a78e890-4853-4834-afbc-60ef34a55b6a" /> 

On Master: 
<img width="1681" height="35" alt="image" src="https://github.com/user-attachments/assets/8fb585ab-37d4-46bf-9aab-7fc30e071bb7" /> 
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" 
<img width="1681" height="33" alt="image" src="https://github.com/user-attachments/assets/e06bc596-349a-47a0-94f6-26e42167162a" /> 
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication 
<img width="1681" height="194" alt="image" src="https://github.com/user-attachments/assets/3aaf7044-f641-4a85-b16c-57413d2b56d8" /> 
docker exec -i etcd etcdctl --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 endpoint status --write-out=table 
<img width="1681" height="104" alt="image" src="https://github.com/user-attachments/assets/76116c6f-432a-4efe-b9f5-9bee8702ff7a" /> 
