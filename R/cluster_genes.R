#' Cluster genes into a specified number of groups based on .
#'
#'
#' @param cds the cell_data_set upon which to perform this operation
#' @param k number of kNN used in creating the k nearest neighbor graph for Louvain clustering. The number of kNN is related to the resolution of the clustering result, bigger number of kNN gives low resolution and vice versa. Default to be 20
#' @param louvain_iter Integer number of iterations used for Louvain clustering. The clustering result gives the largest modularity score will be used as the final clustering result.  Default to be 1. Note that if louvain_iter is large than 1, the `seed` argument will be ignored.
#' @param weight A logic argument to determine whether or not we will use Jaccard coefficent for two nearest neighbors (based on the overlapping of their kNN) as the weight used for Louvain clustering. Default to be FALSE.
#' @param res Resolution parameter for the louvain clustering. Values between 0 and 1e-2 are good, bigger values give you more clusters. Default is set to be `seq(0, 1e-4, length.out = 5)`.
#' @param random_seed  the seed used by the random number generator in louvain-igraph package. This argument will be ignored if louvain_iter is larger than 1.
#' @param verbose Verbose A logic flag to determine whether or not we should print the running details.
#' @param cores number of cores computer should use to execute function
#' @return an updated cell_data_set object, in which phenoData contains values for Cluster for each cell
#' @references Rodriguez, A., & Laio, A. (2014). Clustering by fast search and find of density peaks. Science, 344(6191), 1492-1496. doi:10.1126/science.1242072
#' @references Vincent D. Blondel, Jean-Loup Guillaume, Renaud Lambiotte, Etienne Lefebvre: Fast unfolding of communities in large networks. J. Stat. Mech. (2008) P10008
#' @references Jacob H. Levine and et.al. Data-Driven Phenotypic Dissection of AML Reveals Progenitor-like Cells that Correlate with Prognosis. Cell, 2015.
#'
#' @export

cluster_genes <- function(cds,
                          reduction_method = c("UMAP", "tSNE", "PCA"),
                          max_components = 2,
                          umap.metric = "cosine",
                          umap.min_dist = 0.1,
                          umap.n_neighbors = 15L,
                          umap.fast_sgd = TRUE,
                          umap.nn_method = "annoy",
                          k = 20,
                          louvain_iter = 1,
                          partition_qval = 0.05,
                          weight = FALSE,
                          resolution = NULL,
                          random_seed = 0L,
                          cores=1,
                          verbose = F,
                          ...) {
  method = 'louvain'
  assertthat::assert_that(
    tryCatch(expr = ifelse(match.arg(reduction_method) == "",TRUE, TRUE),
             error = function(e) FALSE),
    msg = "reduction_method must be one of 'UMAP', 'PCA' or 'tSNE'")

  reduction_method <- match.arg(reduction_method)

  assertthat::assert_that(is(cds, "cell_data_set"))
  assertthat::assert_that(is.character(reduction_method))
  assertthat::assert_that(assertthat::is.count(k))
  assertthat::assert_that(is.logical(weight))
  assertthat::assert_that(assertthat::is.count(louvain_iter))
  ## TO DO what is resolution?
  assertthat::assert_that(is.numeric(partition_qval))
  assertthat::assert_that(is.logical(verbose))
  assertthat::assert_that(!is.null(reducedDims(cds)[[reduction_method]]),
                          msg = paste("No dimensionality reduction for",
                                      reduction_method, "calculated.",
                                      "Please run reduce_dimensions with",
                                      "reduction_method =", reduction_method,
                                      "before running cluster_cells"))

  preprocess_mat <- cds@preprocess_aux$gene_loadings
  preprocess_mat = preprocess_mat[rownames(cds),]

  umap_res = uwot::umap(as.matrix(preprocess_mat),
                        n_components = max_components,
                        metric = umap.metric,
                        min_dist = umap.min_dist,
                        n_neighbors = umap.n_neighbors,
                        fast_sgd = umap.fast_sgd,
                        n_threads=cores,
                        verbose=verbose,
                        nn_method= umap.nn_method,
                        ...)

  row.names(umap_res) <- row.names(preprocess_mat)
  colnames(umap_res) = paste0('dim_', 1:ncol(umap_res))
  reduced_dim_res <- umap_res

  if(verbose)
    message("Running louvain clustering algorithm ...")

  louvain_res <- louvain_clustering(data = reduced_dim_res,
                                    pd = rowData(cds)[row.names(reduced_dim_res),,drop=FALSE],
                                    k = k,
                                    weight = weight,
                                    louvain_iter = louvain_iter,
                                    resolution = resolution,
                                    random_seed = random_seed,
                                    verbose = verbose, ...)

  cluster_graph_res <- compute_partitions(louvain_res$g,
                                          louvain_res$optim_res,
                                          partition_qval, verbose)
  partitions <- igraph::components(cluster_graph_res$cluster_g)$membership[louvain_res$optim_res$membership]
  names(partitions) <- row.names(reduced_dim_res)
  partitions <- as.factor(partitions)

  gene_cluster_df = tibble::tibble(id = row.names(preprocess_mat),
                                   cluster = factor(igraph::membership(louvain_res$optim_res)),
                                   supercluster = partitions)
  gene_cluster_df = tibble::as_tibble(cbind(gene_cluster_df, umap_res))

  return(gene_cluster_df)
}

#' Creates a matrix with aggregated expression values for arbitrary groups of genes
#' @export
aggregate_gene_expression <- function(cds,
                                      gene_group_df,
                                      cell_group_df,
                                      norm_method=c("log", "size_only"),
                                      scale_agg_values=TRUE,
                                      max_agg_value=3,
                                      min_agg_value=-3){
  gene_group_df = as.data.frame(gene_group_df)
  gene_group_df = gene_group_df[gene_group_df[,1] %in% fData(cds)$gene_short_name | gene_group_df[,1] %in% row.names(fData(cds)),,drop=FALSE]

  # gene_group_df = gene_group_df[row.names(fData(cds)),]
  # FIXME: this should allow genes to be part of multiple groups. group_by over the second column with a call to colSum should do it.
  agg_mat = as.matrix(Matrix.utils::aggregate.Matrix(exprs(cds)[gene_group_df[,1],], as.factor(gene_group_df[,2]), fun="sum"))
  agg_mat = t(t(agg_mat / size_factors(cds)))
  agg_mat = t(scale(t(log10(agg_mat + 0.1))))

  agg_mat[agg_mat < min_agg_value] = min_agg_value
  agg_mat[agg_mat > max_agg_value] = max_agg_value

  cell_group_df = as.data.frame(cell_group_df)
  cell_group_df = cell_group_df[cell_group_df[,1] %in% row.names(pData(cds)),,drop=FALSE]

  agg_mat = t(as.matrix(Matrix.utils::aggregate.Matrix(t(agg_mat[,cell_group_df[,1]]), as.factor(cell_group_df[,2]), fun="mean")))
  return(agg_mat)
}