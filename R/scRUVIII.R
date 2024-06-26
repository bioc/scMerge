#' @title scRUVIII: RUVIII algorithm optimised for single cell data
#'
#' @description A function to perform location/scale adjustment to data as the input of
#' RUVIII which also provides the option to select optimal RUVk according to the
#' silhouette coefficient
#'
#'
#' @author Yingxin Lin, Kevin Wang
#' @param Y The unnormalised SC data. A m by n matrix, where m is the number of observations and n is the number of features.
#' @param M The replicate mapping matrix.
#' The mapping matrix has m rows (one for each observation), and each column represents a set of replicates.
#' The (i, j)-th entry of the mapping matrix is 1 if the i-th observation is in replicate set j, and 0 otherwise.
#' See ruv::RUVIII for more details.
#' @param ctl An index vector to specify the negative controls.
#' Either a logical vector of length n or a vector of integers.
#' @param fullalpha Not used. Please ignore.
#' @param k The number of unwanted factors to remove. This is inherited from the ruvK argument from the scMerge::scMerge function.
#' @param cell_type An optional vector indicating the cell type information for each cell
#' in the batch-combined matrix. If it is \code{NULL},
#' pseudo-replicate procedure will be run to identify cell type.
#' @param batch Batch information inherited from the scMerge::scMerge function.
#' @param return_all_RUV Whether to return extra information on the RUV function, inherited from the scMerge::scMerge function
#' @param BPPARAM A \code{BiocParallelParam} class object from the \code{BiocParallel} package is used. Default is SerialParam().
#' @param BSPARAM A \code{BiocSingularParam} class object from the \code{BiocSingular} package is used. Default is ExactParam().
#' @param svd_k If BSPARAM is set to \code{RandomParam} or \code{IrlbaParam} class from \code{BiocSingular} package, then 
#' \code{svd_k} will be used to used to reduce the computational cost of singular value decomposition. Default to 50.
#' @importFrom DelayedArray t
#' @importFrom DelayedArray rowMeans
#' @return A list consists of:
#' \itemize{
#' \item{RUV-normalised matrices:} If k has multiple values, then the RUV-normalised matrices using
#' all the supplied k values will be returned.
#' \item{optimal_ruvK:} The optimal RUV k value as determined by silhouette coefficient.
#' }
#' @export
#' @examples
#' L = ruvSimulate(m = 200, n = 1000, nc = 100, nCelltypes = 3, nBatch = 2, lambda = 0.1, sce = FALSE)
#' Y = t(log2(L$Y + 1L)); M = L$M; ctl = L$ctl; batch = L$batch;
#' res = scRUVIII(Y = Y, M = M, ctl = ctl, k = c(5, 10, 15, 20), batch = batch)

scRUVIII <- function(Y = Y, M = M, ctl = ctl, fullalpha = NULL, 
                     k = k, cell_type = NULL, batch = NULL, return_all_RUV = TRUE, 
                     BPPARAM = SerialParam(), BSPARAM = ExactParam(), 
                     svd_k = 50) {
    
    ## Standardise the data
    scale_res <- standardize2(Y, batch)
    stand_tY <- DelayedArray::t(scale_res$stand_Y)
    stand_sd <- sqrt(scale_res$stand_var)
    stand_mean <- scale_res$stand_mean
    
    ruv3_initial <- fastRUVIII(Y = stand_tY, ctl = ctl, k = k[1], 
                               M = M, fullalpha = fullalpha, return.info = TRUE, 
                               BPPARAM = BPPARAM, BSPARAM = BSPARAM, 
                               svd_k = svd_k)
    
    ruv3_initial$k <- k
    ## The computed result is ruv3res_list.  If we have only one
    ## ruvK value, then the result is ruv3res_list with only one
    ## element, corresponding to our initial run.
    ruv3res_list = vector("list", length = length(k))
    ruv3res_list[[1]] = ruv3_initial
    
    if (length(k) == 1) {
        
    } else {
        ## If we have more than one ruvK value then we feed the result
        ## to the ruv::RUVIII function (there is no need for BSPARAM,
        ## since we already have the fullalpha)
        for (i in 2:length(k)) {
            ruv3res_list[[i]] = fastRUVIII(Y = stand_tY, ctl = ctl, 
                                           k = k[i], M = M, fullalpha = ruv3_initial$fullalpha,
                                           return.info = TRUE)
        }  ## End for loop
    }  ## End else(length(k) == 1)
    
    names(ruv3res_list) = k
    ## Caculate sil. coef and F-score to select the best RUVk
    ## value.  No need to run for length(k)==1
    if (length(k) == 1) {
        f_score <- 1
        names(f_score) <- k
    } else {
        ## Cell type information will be used for calculating sil.coef
        ## and F-score
        cat("Selecting optimal RUVk \n")
        
        if (is.null(cell_type)) {
            cat("No cell type info, replicate matrix will be used as cell type info \n")
            cell_type <- apply(M, 1, function(x) which(x == 1))
        }
        ## Computing the silhouette coefficient from kBET package
        sil_res <- do.call(cbind, lapply(ruv3res_list, FUN = calculateSil, 
                                         BSPARAM = BSPARAM,
                                         cell_type = cell_type, batch = batch))
        ## Computing the F scores based on the 2 silhouette
        ## coefficients
        f_score <- rep(NA, ncol(sil_res))
        
        for (i in seq_len(length(k))) {
            f_score[i] <- f_measure(zeroOneScale(sil_res[1, ])[i], 
                                    1 - zeroOneScale(sil_res[2, ])[i])
        }
        names(f_score) <- k
        
        message("optimal ruvK:", k[which.max(f_score)])
        
        ## Not showing
        graphics::plot(k, f_score, pch = 16, col = "light grey")
        graphics::lines(k, f_score)
        graphics::points(ruv3_initial$k[which.max(f_score)], 
                         f_score[[which.max(f_score)]], col = "red", pch = 16)
        
    }
    
    ## Add back the mean and sd to the normalised data
    for (i in seq_len(length(ruv3res_list))) {
        ruv3res_list[[i]]$newY <- t((t(ruv3res_list[[i]]$newY) * stand_sd + stand_mean))
    }
    ## ruv3res_list is all the normalised matrices ruv3res_optimal
    ## is the one matrix having the maximum F-score
    ruv3res_optimal <- ruv3res_list[[which.max(f_score)]]
    
    
    
    if (return_all_RUV) {
        ## If return_all_RUV is TRUE, we will return all the
        ## normalised matrices
        ruv3res_list$optimal_ruvK <- k[which.max(f_score)]
        return(ruv3res_list)
    } else {
        ## If return_all_RUV is FALSE, we will return the F-score
        ## optimal matrix
        ruv3res_optimal$optimal_ruvK <- k[which.max(f_score)]
        return(ruv3res_optimal)
    }
}  ## End scRUVIII function








####################################################### 
zeroOneScale <- function(v) {
    v <- (v + 1)/2
    return(v)
}

###############################
solve_axb = function(a, b){
    x = solve(DelayedArray::t(a) %*% a) %*% DelayedArray::t(a) %*% b
    return(x)
}
###############################
standardize2 <- function(Y, batch) {
    num_cell <- ncol(Y)
    num_batch <- length(unique(batch))
    batch <- as.factor(batch)
    stand_mean <- DelayedArray::rowMeans(Y)
    design <- stats::model.matrix(~-1 + batch)
    B.hat = solve_axb(a = DelayedArray::t(design) %*% design,
                      b = DelayedArray::t(Y %*% design))
    B.hat = DelayedArray::DelayedArray(B.hat)
    B_designed <- DelayedArray::t(B.hat) %*% DelayedArray::t(design)
    B_designed <- DelayedArray::DelayedArray(B_designed)
    Y <- DelayedArray::DelayedArray(Y)
    stand_var <- DelayedArray::rowSums(((Y - B_designed)^2))/(num_cell - num_batch)
    stand_Y <- (Y-stand_mean)/sqrt(stand_var)
    return(res = list(stand_Y = stand_Y, 
                      stand_mean = stand_mean, 
                      stand_var = stand_var))
}
####################################################### 
f_measure <- function(cell_type, batch) {
    f <- 2 * (cell_type * batch)/(cell_type + batch)
    return(f)
}
####################################################### 
calculateSil <- function(x, BSPARAM, cell_type, batch) {
    pca.data <- BiocSingular::runPCA(x = x$newY, rank = 10, scale = TRUE, center = TRUE,
                                     BSPARAM = BSPARAM)
    
    result = c(kBET_batch_sil(pca.data, as.numeric(as.factor(cell_type)), 
                              nPCs = 10), kBET_batch_sil(pca.data, as.numeric(as.factor(batch)), 
                                                         nPCs = 10))
    return(result)
}

kBET_batch_sil <- function(pca.data, batch, nPCs = 10) {
    ## This function was copied from kBET, which cannot be
    ## imported because it is only a GitHub package
    dd <- as.matrix(stats::dist(pca.data$x[, seq_len(nPCs)]))
    score_sil <- summary(cluster::silhouette(as.numeric(batch), 
                                             dd))$avg.width
    return(score_sil)
}

