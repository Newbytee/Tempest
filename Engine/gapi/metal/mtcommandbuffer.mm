#include "mtcommandbuffer.h"

#include "mtbuffer.h"
#include "mtdevice.h"
#include "mtpipeline.h"
#include "mtpipelinelay.h"
#include "mtdescriptorarray.h"
#include "mttexture.h"
#include "mtswapchain.h"

#include <Metal/MTLCommandQueue.h>

using namespace Tempest;
using namespace Tempest::Detail;

static MTLLoadAction mkLoadOp(const AccessOp m) {
  switch(m) {
    case AccessOp::Clear:    return MTLLoadActionClear;
    case AccessOp::Preserve: return MTLLoadActionLoad;
    case AccessOp::Discard:  return MTLLoadActionDontCare;
    }
  return MTLLoadActionDontCare;
  }

static MTLStoreAction mkStoreOp(const AccessOp m) {
  switch(m) {
    case AccessOp::Clear:    return MTLStoreActionStore;
    case AccessOp::Preserve: return MTLStoreActionStore;
    case AccessOp::Discard:  return MTLStoreActionDontCare;
    }
  return MTLStoreActionDontCare;
  }

static MTLClearColor mkClearColor(const Vec4& c) {
  MTLClearColor ret;
  ret.red   = c.x;
  ret.green = c.y;
  ret.blue  = c.z;
  ret.alpha = c.w;
  return ret;
  }

MtCommandBuffer::MtCommandBuffer(MtDevice& dev)
  : device(dev) {
  reset();
  }

MtCommandBuffer::~MtCommandBuffer() {
  [impl release];
  }

bool MtCommandBuffer::isRecording() const {
  // FIXME
  return encDraw!=nil && encComp!=nil && encBlit!=nullptr;
  }

void MtCommandBuffer::begin() {
  reset();
  }

void MtCommandBuffer::end() {
  setEncoder(E_None,nullptr);
  }

void MtCommandBuffer::reset() {
  MTLCommandBufferDescriptor* desc = [MTLCommandBufferDescriptor new];
  desc.retainedReferences = NO;

  impl = [device.queue commandBufferWithDescriptor:desc];
  [impl retain];
  [desc release];
  }

void MtCommandBuffer::beginRendering(const AttachmentDesc* d, size_t descSize,
                                     uint32_t width, uint32_t height, const TextureFormat* frm,
                                     AbstractGraphicsApi::Texture** att,
                                     AbstractGraphicsApi::Swapchain** sw, const uint32_t* imgId) {
  curFbo.depthFormat = MTLPixelFormatInvalid;
  curFbo.numColors   = 0;

  MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
  for(size_t i=0; i<descSize; ++i) {
    auto& dx = d[i];
    if(dx.zbuffer!=nullptr) {
      auto& t = *reinterpret_cast<MtTexture*>(att[i]);
      desc.depthAttachment.texture     = t.impl;
      desc.depthAttachment.loadAction  = mkLoadOp (dx.load);
      desc.depthAttachment.storeAction = mkStoreOp(dx.store);
      desc.depthAttachment.clearDepth  = dx.clear.x;
      curFbo.depthFormat               = nativeFormat(frm[i]);
      continue;
      }
    if(sw[i]!=nullptr) {
      auto& s = *reinterpret_cast<MtSwapchain*>(sw[i]);
      desc.colorAttachments[i].texture     = s.img[imgId[i]].tex;
      curFbo.colorFormat[curFbo.numColors] = s.format();
      } else {
      auto& t = *reinterpret_cast<MtTexture*>(att[i]);
      desc.colorAttachments[i].texture     = t.impl;
      curFbo.colorFormat[curFbo.numColors] = nativeFormat(frm[i]);
      }
    desc.colorAttachments[i].loadAction  = mkLoadOp    (dx.load);
    desc.colorAttachments[i].storeAction = mkStoreOp   (dx.store);
    desc.colorAttachments[i].clearColor  = mkClearColor(dx.clear);
    ++curFbo.numColors;
    }

  setEncoder(E_Draw,desc);

  // [enc setFrontFacingWinding:MTLWindingCounterClockwise];
  setViewport(Rect(0,0,width,height));
  }

void MtCommandBuffer::endRendering() {
  setEncoder(E_None,nullptr);
  }

void MtCommandBuffer::barrier(const AbstractGraphicsApi::BarrierDesc* desc, size_t cnt) {
  // nop
  }

void MtCommandBuffer::setEncoder(MtCommandBuffer::EncType e, MTLRenderPassDescriptor* desc) {
  if(encDraw!=nil && e!=E_Draw) {
    [encDraw endEncoding];
    [encDraw release];
    encDraw = nil;
    }
  if(encComp!=nil && e!=E_Comp) {
    [encComp endEncoding];
    [encComp release];
    encComp = nil;
    }
  if(encBlit!=nil && e!=E_Blit) {
    [encBlit endEncoding];
    [encBlit release];
    encBlit = nil;
    }

  switch(e) {
    case E_None: {
      break;
      }
    case E_Draw: {
      if(encDraw!=nil) {
        [encDraw endEncoding];
        [encDraw release];
        }
      encDraw = [impl renderCommandEncoderWithDescriptor:desc];
      [encDraw retain];
      break;
      }
    case E_Comp: {
      if(encComp!=nil)
        return;
      encComp = [impl computeCommandEncoder];
      [encComp retain];
      break;
      }
    case E_Blit: {
      if(encBlit!=nil)
        return;
      encBlit = [impl blitCommandEncoder];
      [encBlit retain];
      break;
      }
    }
  }

void MtCommandBuffer::setComputePipeline(AbstractGraphicsApi::CompPipeline &p) {
  setEncoder(E_Comp,nullptr);
  auto& px = reinterpret_cast<MtCompPipeline&>(p);
  [encComp setComputePipelineState:px.impl];
  curLay   = px.lay.handler;
  maxTotalThreadsPerThreadgroup = px.impl.maxTotalThreadsPerThreadgroup;
  }

void MtCommandBuffer::setBytes(AbstractGraphicsApi::Pipeline&,
                               const void *data, size_t size) {
  implSetBytes(data,size);
  }

void MtCommandBuffer::setUniforms(AbstractGraphicsApi::Pipeline&,
                                  AbstractGraphicsApi::Desc &u) {
  implSetUniforms(u);
  }

void MtCommandBuffer::setBytes(AbstractGraphicsApi::CompPipeline&,
                               const void *data, size_t size) {
  implSetBytes(data,size);
  }

void MtCommandBuffer::setUniforms(AbstractGraphicsApi::CompPipeline&,
                                  AbstractGraphicsApi::Desc &u) {
  implSetUniforms(u);
  }

void MtCommandBuffer::setViewport(const Rect &r) {
  MTLViewport v = {};
  v.originX = r.x;
  v.originY = r.y;
  v.width   = r.w;
  v.height  = r.h;
  v.znear   = 0;
  v.zfar    = 1;

  [encDraw setViewport:v];
  }

void MtCommandBuffer::setScissor(const Rect& r) {
  int x0 = std::max(0,r.x), y0 = std::max(0,r.y);
  int w  = (r.x+r.w)-x0, h = (r.y+r.h)-y0;

  MTLScissorRect v = {};
  v.x      = x0;
  v.y      = y0;
  v.width  = w;
  v.height = h;
  [encDraw setScissorRect:v];
  }

void MtCommandBuffer::draw(const AbstractGraphicsApi::Buffer& ivbo, size_t offset, size_t vertexCount,
                           size_t firstInstance, size_t instanceCount) {
  auto& vbo = reinterpret_cast<const MtBuffer&>(ivbo);
  [encDraw setVertexBuffer:vbo.impl
                    offset:0
                   atIndex:curVboId];

  if(!isTesselation) {
    [encDraw drawPrimitives:topology
                        vertexStart:offset
                        vertexCount:vertexCount
                        instanceCount:instanceCount
                        baseInstance:firstInstance];
    } else {
    [encDraw setTriangleFillMode:MTLTriangleFillModeLines]; // debug
    [encDraw setTessellationFactorBuffer : nil
                                  offset : 0
                          instanceStride : 0];
    [encDraw drawPatches: 3
             patchStart: offset
             patchCount: vertexCount
             patchIndexBuffer: nil
             patchIndexBufferOffset: 0
             instanceCount: instanceCount
             baseInstance: firstInstance];
    }
  }

void MtCommandBuffer::drawIndexed(const AbstractGraphicsApi::Buffer& ivbo, size_t voffset,
                                  const AbstractGraphicsApi::Buffer& iibo, Detail::IndexClass icls, size_t ioffset, size_t isize,
                                  size_t firstInstance, size_t instanceCount) {
  auto&    vbo     = reinterpret_cast<const MtBuffer&>(ivbo);
  auto&    ibo     = reinterpret_cast<const MtBuffer&>(iibo);
  auto     iboType = nativeFormat(icls);
  uint32_t mul     = sizeofIndex(icls);

  [encDraw setVertexBuffer:vbo.impl
                    offset:0
                   atIndex:curVboId];
  [encDraw drawIndexedPrimitives:topology
                             indexCount:isize
                             indexType:iboType
                             indexBuffer:ibo.impl
                             indexBufferOffset:ioffset*mul
                             instanceCount:instanceCount
                             baseVertex:voffset
                             baseInstance:firstInstance
                             ];
  }

void MtCommandBuffer::dispatch(size_t x, size_t y, size_t z) {
  MTLSize sz;
  sz.width  = x;
  sz.height = y;
  sz.depth  = z;

  MTLSize th;
  th.width  = 1;
  th.height = 1;
  th.depth  = 1;

  [encComp dispatchThreadgroups:sz threadsPerThreadgroup:th];
  }

void MtCommandBuffer::implSetBytes(const void* bytes, size_t sz) {
  auto& mtl = curLay->bindPush;
  auto& l   = curLay->pb;

  if(l.stage==0)
    return;
  char tmp[256] = {};
  if(sz!=l.size) {
    std::memcpy(tmp,bytes,sz);
    bytes = tmp;
    sz    = l.size;
    }
  if(mtl.bindVs!=uint32_t(-1)) {
    [encDraw setVertexBytes:bytes length:sz atIndex:mtl.bindVs];
    }
  if(mtl.bindFs!=uint32_t(-1)) {
    [encDraw setFragmentBytes:bytes length:sz atIndex:mtl.bindFs];
    }
  if(mtl.bindCs!=uint32_t(-1)) {
    [encComp setBytes:bytes length:sz atIndex:mtl.bindCs];
    }
  }

void MtCommandBuffer::implSetUniforms(AbstractGraphicsApi::Desc& u) {
  auto& d   = reinterpret_cast<MtDescriptorArray&>(u);
  auto& lay = curLay->lay;
  auto& mtl = curLay->bind;
  for(size_t i=0; i<lay.size(); ++i) {
    auto& l = lay[i];
    if(l.stage==0)
      continue;
    switch(l.cls) {
      case ShaderReflection::Push:
      case ShaderReflection::Count:
        break;
      case ShaderReflection::Ubo:
      case ShaderReflection::SsboR:
      case ShaderReflection::SsboRW:
        setBuffer(mtl[i],d.desc[i].val,d.desc[i].offset);
        break;
      case ShaderReflection::Texture:
      case ShaderReflection::ImgR:
      case ShaderReflection::ImgRW:
        setTexture(mtl[i],d.desc[i].val,d.desc[i].sampler);
        break;
      case ShaderReflection::Tlas:
        setTlas(mtl[i],d.desc[i].val);
        break;
      }
    }
  }

void MtCommandBuffer::setBuffer(const MtPipelineLay::MTLBind& mtl,
                                id<MTLBuffer> buf, size_t offset) {
  if(mtl.bindVs!=uint32_t(-1)) {
    [encDraw setVertexBuffer:buf offset:offset atIndex:mtl.bindVs];
    }
  if(mtl.bindFs!=uint32_t(-1)) {
    [encDraw setFragmentBuffer:buf offset:offset atIndex:mtl.bindFs];
    }
  if(mtl.bindCs!=uint32_t(-1)) {
    [encComp setBuffer:buf offset:offset atIndex:mtl.bindCs];
    }
  }

void MtCommandBuffer::setTexture(const MtPipelineLay::MTLBind& mtl,
                                 id<MTLTexture> tex, id<MTLSamplerState> ss) {
  if(mtl.bindVs!=uint32_t(-1))
    [encDraw setVertexTexture:tex atIndex:mtl.bindVs];
  if(mtl.bindVsSmp!=uint32_t(-1))
    [encDraw setVertexSamplerState:ss atIndex:mtl.bindVsSmp];

  if(mtl.bindFs!=uint32_t(-1))
    [encDraw setFragmentTexture:tex atIndex:mtl.bindFs];
  if(mtl.bindFsSmp!=uint32_t(-1))
    [encDraw setFragmentSamplerState:ss atIndex:mtl.bindFsSmp];

  if(mtl.bindCs!=uint32_t(-1))
    [encComp setTexture:tex atIndex:mtl.bindCs];
  if(mtl.bindCsSmp!=uint32_t(-1))
    [encComp setSamplerState:ss atIndex:mtl.bindCsSmp];
  }

void MtCommandBuffer::setTlas(const MtPipelineLay::MTLBind& mtl,
                              id<MTLAccelerationStructure> as) {
  if(@available(macOS 12.0, *)) {
    if(mtl.bindVs!=uint32_t(-1)) {
      [encDraw setVertexAccelerationStructure:as atBufferIndex:mtl.bindVs];
      }
    if(mtl.bindFs!=uint32_t(-1)) {
      [encDraw setFragmentAccelerationStructure:as atBufferIndex:mtl.bindFs];
      }
    } else {
    if(mtl.bindVs!=uint32_t(-1) ||
       mtl.bindFs!=uint32_t(-1))
      throw std::system_error(Tempest::GraphicsErrc::UnsupportedExtension);
    }

  if(mtl.bindCs!=uint32_t(-1)) {
    [encComp setAccelerationStructure:as atBufferIndex:mtl.bindCs];
    }
  }

void MtCommandBuffer::generateMipmap(AbstractGraphicsApi::Texture &image,
                                     uint32_t /*texWidth*/, uint32_t /*texHeight*/,
                                     uint32_t /*mipLevels*/) {
  setEncoder(E_Blit,nullptr);

  auto& t = reinterpret_cast<MtTexture&>(image);
  [encBlit generateMipmapsForTexture:t.impl];
  }

void MtCommandBuffer::setPipeline(AbstractGraphicsApi::Pipeline &p) {
  auto& px   = reinterpret_cast<MtPipeline&>(p);
  auto& inst = px.inst(curFbo);

  if(curFbo.depthFormat!=MTLPixelFormatInvalid)
    [encDraw setDepthStencilState:px.depthStZ]; else
    [encDraw setDepthStencilState:px.depthStNoZ];
  [encDraw setRenderPipelineState:inst.pso];
  [encDraw setCullMode:px.cullMode];
  topology      = px.topology;
  isTesselation = px.isTesselation;
  curVboId      = px.lay.handler->vboIndex;
  curLay        = px.lay.handler;
  }

void MtCommandBuffer::copy(AbstractGraphicsApi::Buffer& dest, size_t offset,
                           AbstractGraphicsApi::Texture& src, uint32_t width, uint32_t height, uint32_t mip) {
  setEncoder(E_Blit,nullptr);

  auto& s = reinterpret_cast<MtTexture&>(src);
  auto& d = reinterpret_cast<MtBuffer&> (dest);
  const uint32_t bpp = s.bitCount()/8;

  [encBlit copyFromTexture:s.impl
                           sourceSlice:0
                           sourceLevel:mip
                           sourceOrigin:MTLOriginMake(0,0,0)
                           sourceSize:MTLSizeMake(width,height,1)
                           toBuffer:d.impl
                           destinationOffset:offset
                           destinationBytesPerRow:bpp*width
                           destinationBytesPerImage:bpp*width*height];
  }

