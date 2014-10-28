#!/usr/bin/env python

def fd_jenkinson_for_afni(in_file, out_file_templ=None):
    """
    Method to calculate Framewise Displacement (FD) calculations
    (Jenkinson et al., 2002)
    
    
    Parameters
    ----------
    
    in_file : string
        Should be the output from 3dvolreg's *.affmat12.1D file using the -1dmatrix_save option
    
    out_file_templ : string (optional)
        Should be a template string indicating the two output files (absolute 
        and relative measures). The template should include one '%s' as in 
        'motion_%s.1D' where the '%s' will be replaced by 'abs' or 'rel' for 
        the absolute or relative framewise displacement measures. If this 
        argument is not provided, no output will be saved to disk.


    Returns
    -------
    
    fd_mat : np.array
        Two column numpy array with the absolute and relative FD measures.

    
    Notes
    -----
    
    TODO?
    

    Authors
    -------
    - Zarrar (Oct 2014) - incorporated absolute measure
    - Kris Gorg (?) - cleaned up code
    - Krsna (May 2013) - fixed to use afni coordinate transforms
    - CPAC Team
    """
    
    import numpy as np
    import os
    import sys
    import math
   
    # read in the rigid body transform matrices
    pm_ = np.genfromtxt(in_file)
    
    # make the 3x4 matrix into a 4x4
    pm  = np.zeros((pm_.shape[0],pm_.shape[1]+4))
    pm[:,:12] = pm_
    pm[:,12:] = [0.0, 0.0, 0.0, 1.0]
    
    # default radius (as in FSL) of a sphere represents the brain
    rmax = 80.0
        
    # calculate the absolute FD - based on chao-gan code
    # then calculate the relative FD
    # TODO:
    # - ask to confirm that the output from afni is the rigid-body transform? i do think 3dallineate has this
    # - ask to confirm that we don't need the center coordinates?
    
    ## Absolute FD
    ntpts   = pm.shape[0]
    abs_FDs = np.zeros(ntpts)
    for i in range(0, ntpts):
        MA1 = np.matrix(np.eye(4))
    	MA2 = np.matrix(pm[i].reshape(4,4)) # making use of the fact that the order of aff12 matrix is "row-by-row"
        
        M   = np.dot(MA1, MA2.I) - np.eye(4)
        
        A   = M[0:3, 0:3]
        b   = M[0:3, 3]
        
        FD_J = math.sqrt((rmax*rmax/5)*np.trace(np.dot(A.T, A)) + np.dot(b.T, b))
        abs_FDs[i] = FD_J
    
    ## Relative FD
    rel_FDs = np.zeros(ntpts) # 1st pt is 0 since rel fd is movement from t-1 to t
    for i in range(1, ntpts):
        MA1 = np.matrix(pm[i-1].reshape(4,4))
    	MA2 = np.matrix(pm[i].reshape(4,4)) # making use of the fact that the order of aff12 matrix is "row-by-row"
        
        M   = np.dot(MA1, MA2.I) - np.eye(4)
        
        A   = M[0:3, 0:3]
        b   = M[0:3, 3]
        
        FD_J = math.sqrt((rmax*rmax/5)*np.trace(np.dot(A.T, A)) + np.dot(b.T, b))
        rel_FDs[i] = FD_J
    
    if out_file_templ is not None:
        if out_file_templ.find("%s") < 0:
            raise Exception("Could not find substitution '%s' in out_file_templ")
        np.savetxt(out_file_templ % "abs", abs_FDs, "%f")
        np.savetxt(out_file_templ % "rel", rel_FDs, "%f")
    
    fds = np.vstack((abs_FDs, rel_FDs)).T
    return fds


if  __name__ == '__main__':
    import sys
    args = sys.argv[1:]
    if len(args) != 2:
        print "Usage: %s input-matfile output-prefix" % sys.argv[0]
        sys.exit(2)
    infile      = args[0]
    outprefix   = args[1]

    fd_jenkinson_for_afni(infile, outprefix + "_%s.1D")
