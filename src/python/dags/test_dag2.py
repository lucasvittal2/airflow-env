from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.dummy import DummyOperator
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

dag = DAG('hello_world', description='Hello World DAG',
          schedule_interval='0 12 * * *',
          start_date=datetime(2022, 8, 24), catchup=False)

def print_hello():
    print("Hello world!")
hello_operator = PythonOperator(task_id='hello_task', python_callable=print_hello, dag=dag)

hello_operator