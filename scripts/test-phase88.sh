#!/bin/bash

echo "=== DATE ==="
date

echo
echo "=== LSPCI ==="
lspci -nn | grep -i audio

echo
echo "=== MODULES ==="
lsmod | grep snd

echo
echo "=== ALSA ==="
aplay -l

echo
echo "=== DMESG ==="
dmesg | tail -100
