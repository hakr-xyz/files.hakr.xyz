#!/bin/bash

file_name="hello.txt"

echo "Hello World"
touch ~/$file_name
echo "Hello $(date +%s)" >> ~/$file_name
