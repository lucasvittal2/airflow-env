from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
import airflow
import numpy as np

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
    'email_on_failure': False,
    'email_on_retry': False,
}


def print_hello():
    """Simple Python function that prints hello"""
    print("Hello world from Airflow!")
    print(f"Running on Airflow version: {airflow.__version__}")
    return "Hello world task completed successfully"


def print_date():
    """Print current date and time"""
    array = np.array([1, 2, 3])
    array2 = np.array([3, 4, 5])
    result = np.dot(array, array2)
    print(f"dot product result: {result}")
    current_time = datetime.now()
    print(f"Current time: {current_time}")
    return current_time


# Check Airflow version for compatibility
airflow_version = tuple(map(int, airflow.__version__.split('.')[:2]))

# Use appropriate schedule parameter based on version
dag_kwargs = {
    'dag_id': 'hello_world_compatible',
    'description': 'Hello World DAG - Version Compatible',
    'start_date': datetime(2025, 1, 1),
    'catchup': False,
    'tags': ['test', 'tutorial', 'hello-world', 'compatible'],
    'default_args': default_args,
    'max_active_runs': 1,
}

# Add schedule parameter based on Airflow version
if airflow_version >= (2, 4):
    dag_kwargs['schedule'] = timedelta(minutes=10)  # New format
else:
    dag_kwargs['schedule_interval'] = timedelta(minutes=10)  # Old format

with DAG(**dag_kwargs) as dag:
    hello_task = PythonOperator(
        task_id='say_hello',
        python_callable=print_hello,
        doc_md="""
        ## Hello Task
        This task prints 'Hello world!' and Airflow version to the logs.
        """
    )

    date_task = PythonOperator(
        task_id='print_current_date',
        python_callable=print_date,
        doc_md="""
        ## Date Task  
        This task prints the current date and time.
        """
    )

    # Set task dependencies
    hello_task >> date_task
