The results from these tools are estimations, the true impact of a server may vary due to many factors including, but not limited to: 

- The quantity, and weight, of PSUs for the server
    - The system uses the Boavizta default power supply configuration (1 PSU weighing 5kg) 
    - Testing shows that the power supply configuration does not effect the usage GWP 
- The cleanliness of power provided to the data center
    - Scripts determines the country the server is running in and uses Boaviztas power metrics for that region
- Hardware specs vs instance type evaluation
    - Instance type evaluations will likely output lower numbers than the method which determines the hardware specifictions due to instance types sharing resources 
- The presence of GPUs
    - Boavizta's API does not yet calculate anything for GPU power/carbon consumption
