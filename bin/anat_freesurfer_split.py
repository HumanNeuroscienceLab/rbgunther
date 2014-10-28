#!/usr/bin/env python

# this will split the input file labels into several different output files

import sys
import os
from os import path
import pandas as pd
import numpy as np
import nibabel as nb

# system arguments:
# infile: aseg2raw.nii.gz
# outdir: directory to store individual anatomical labels

def volume_to_rois(infile, outdir):
    labdir = path.join(path.dirname(path.dirname(path.realpath(__file__))), "etc")

    #infile = '/mnt/nfs/psych/faceMemoryMRI/analysis/freesurfer/tb9226/labels2vol/aseg2raw.nii.gz'
    #outdir = "/mnt/nfs/psych/faceMemoryMRI/analysis/freesurfer/tb9226/labels2vol/tmp"
    if not path.exists(outdir):
        os.mkdir(outdir)

    # Read in the data
    print "Reading in data"
    img = nb.load(infile)
    dat = img.get_data()

    # Find the unique anatomical regions
    print "Finding unique anatomical regions"
    uniq = np.unique(dat[dat!=0])
    uniq = np.sort(uniq)
    n    = len(uniq)

    # Get the labels and corresponding index with ROIs
    print "Processing ROI labels"
    labels  = pd.read_table('%s/freesurfer_aseg_labels.txt' % labdir, sep='[ ]*', engine='python')
    uidx    = [ list(labels.id).index(u) for u in uniq  ]
    ulabs   = [ labels.name[i] for i in uidx  ]
    unames  = [ l.replace('-', '_').lower() for l in ulabs ]

    # Select only some ROIs to be output
    # TODO

    # Save
    print "Saving"
    for i in range(n):
        roi     = uniq[i]
        name    = unames[i]
        print "...%s" % name
    
        new_dat = np.zeros_like(dat)
        new_dat[dat==roi] = 1
        # Output image
        new_img = nb.Nifti1Image(new_dat, img.get_affine(), img.get_header())
        nb.save(new_img, '%s/%s.nii.gz' % (outdir, name))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print "usage: $0 infile outdir"
        sys.exit(2)
    
    infile = sys.argv[1]
    outdir = sys.argv[2]
    
    volume_to_rois(infile, outdir)

    