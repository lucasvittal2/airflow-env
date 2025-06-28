from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def print_hello():
    """Simple Python function that prints hello"""
    print("Hello world!")

with DAG(
    dag_id='hello_world',
    description='Hello World DAG',
    schedule_interval='0 12 * * *',
    start_date=datetime(2022, 8, 24),
    catchup=False,
    tags=['test', 'tutorial'],
    default_args=default_args
) as dag:

    hello_operator = PythonOperator(
        task_id='hello_task',
        python_callable=print_hello,
        doc_md="""Prints 'Hello world!' to the logs"""
    )

    hello_operator