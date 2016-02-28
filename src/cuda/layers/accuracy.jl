type CuAccuracycustate{T}
  tmp_blob  :: CuTensorBlob{T}
  accuracy  :: Array{T,1}
  N         :: Int
end
function setup_etc(backend::GPUBackend, layer::AccuracyLayer, op_dim::Int, inputs)
  dims = [size(inputs[1])...]
  dims[op_dim] = 1
  data_type = eltype(inputs[1])
  tmp_blob = make_blob(backend, data_type, dims...)
  accuracy = data_type[0]
  return CuAccuracycustate{data_type}(tmp_blob, accuracy, 0)
end
function shutdown(backend::GPUBackend, state::AccuracyLayerState)
  custate = state.etc
  destroy(custate.tmp_blob)
end

function forward(backend::GPUBackend, state::AccuracyLayerState, inputs::Vector{Blob})
  pred = inputs[1]
  label = inputs[2]
  custate = state.etc

  spatial_dim, pred_dim, num = split_dims(pred, state.op_dim)
  data_type = eltype(pred)

  x_block = round(Int, ceil(convert(Float64, num)/CUDA.THREADS_PER_BLOCK_X));
  y_block = round(Int, ceil(convert(Float64, spatial_dim)/CUDA.THREADS_PER_BLOCK_Y));

  if data_type == Float32
    kernel = backend.mocha.accuracy_forward_float
  elseif data_type == Float64
    kernel = backend.mocha.accuracy_forward_double
  else
    error("Unsupported data type $data_type")
  end
  CUDA.launch(kernel, (x_block,y_block),(CUDA.THREADS_PER_BLOCK_X,CUDA.THREADS_PER_BLOCK_Y),
      (pred.ptr.p, label.ptr.p, custate.tmp_blob.ptr.p, num, pred_dim, spatial_dim));

  N = num * spatial_dim

  CuBLAS.dot(backend.cublas_ctx, custate.accuracy, N, custate.tmp_blob.ptr, 1, custate.tmp_blob.ptr, 1)

  custate.N = N
end

function sync(backend::GPUBackend, state::AccuracyLayerState)
  custate = state.etc
  CudaRT.sync_stream(backend.stream)

  # accumulate accuracy
  state.accuracy = (state.accuracy * state.n_accum + custate.accuracy[1]) / (custate.N + state.n_accum)
  state.n_accum += custate.N
end