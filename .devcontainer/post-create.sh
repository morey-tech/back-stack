#!/bin/bash

echo "post-create start" >> ~/status

# this runs in background after UI is available

echo alias k=kubectl >> /home/vscode/.bashrc

echo "post-create complete" >> ~/status