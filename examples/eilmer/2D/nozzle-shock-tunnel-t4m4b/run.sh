#!/bin/bash
# run.sh
e4shared --run --job=t4m4b --verbosity=1 --max-cpus=4
# mpirun -np 4 e4mpi --run --job=t4m4b --verbosity=1
