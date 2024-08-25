# GodotGaussianSplatting
A toy 3D Gaussian splatting viewer in the Godot Engine based on the paper ["3D Gaussian Splatting for Real-Time Radiance Field Rendering"](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). The viewing engine allows loading `.ply` files containing Gaussian splatting data. Seemless switching between orbit and free-look camera modes allow for intuitive traversal of scenes.

![demo](https://github.com/user-attachments/assets/a83c4cb8-ee3e-4d4f-ba64-341e36dbeebf)

## Introduction
TODO 🗿

**Note:** This project only contains a minimal model as a sample for viewing. Models used in the original paper be found in its associated [GitHub repo](https://github.com/graphdeco-inria/gaussian-splatting) (or directly downloaded via this [link](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/datasets/pretrained/models.zip)). Additional models in `.ply` format can be found on services such as [Polycam](https://poly.cam/) (not free).

## Results

### Splat Rendering
A tile-based rasterizer is implemented entirely through compute shaders using Godot's RenderingDevice abstraction (in a similar manner to the CUDA approach used in the original paper). The rasterization pipeline is comprised of four stages:
  1. **Projection** - Frustum culling is first applied against input Gaussians' means (world-space positions). The 3D covariance for each Gaussian is then calculated using its provided scale and quaternion before being projected into view-space.
    
     A bounding-box for each 'splatted' Gaussian is estimated using the eigenvalues of the projected covariance. For each tile that a bounding-box intersects, a key-value pair is generated: the key, comprised of 16-bits representing the tile's ID + 16-bits representing the view-space depth of the splat; and the value, comprised of a pointer to the splat.

     Additionally, the color of the splat is calculated from the provided spherical harmonic coefficients and the view vector.
  4. **Sorting** - Key-value pairs are sorted such that pairs representing the same tile are contiguous memory and sorted by view-space depth.
  5. **Bounding** - The bounds of each tile are calculated by checking each pair of tile IDs. This defines the range of splats that need to be processed per tile.
  6. **Rendering** - Each pixel traverses across all splats within its tile, back-to-front, blending color against its premultiplied alpha. Rendering stops when the accumulated alpha rises above a threshold value (a sufficient opacity has been reached).

The pipeline can also optionally return the world-space position of the splat nearest to the cursor to be read back on the CPU. This is not related to rendering and exists only for performance reasons. 

When all is said and done, we get radience field rendering at real-time speeds with a quality often surpassing previous methods! (e.g., NeRF)

![rendering_demo](https://github.com/user-attachments/assets/20366e98-a733-416f-8fff-b865896e3e05)

### Scene Interaction
The real-time performance provided by Gaussian splatting allows for rendering large open scenes atop single, isolated objects. To address this varity of environments, the viewing engine allows seemless switching between two camera modes: **free-look nide** mode (enabled by right mouse button), used for freely traversing open spaces; and **orbit mode** (enabled by holding left mouse button), used for focusing on isolated objects. 

To allow moving across large distances quickly, a cursor (whose position can be changed by left-clicking) can be projected into the scene to be focused on by the camera. The cursor also acts as the point-of-interest in orbit mode.

Many models are not world-space up-vector-oriented after training and must be corrected manually. While the viewer does not allow editing the scene data directly, the camera's basis can be overwritten from the current view to reorient the scene.

[movement_demo.mp4](https://github.com/user-attachments/assets/63ed7619-53e8-418e-8cef-c6de8b10b2a6)


### Performance
On a 3060ti, the `bicycle.ply` model from the original paper at 30K iterations at 108 FPS with 3.07GB VRAM allocated.

In general, the majority of frame time is spent in the sorting and rendering stages. For sorting, an efficient GPU radix sort kernel was utilized. For rendering, splats are loaded into shared memory in chunks, utilizing coalesced loads for efficient memory access. Each thread is assigned to a pixel and each thread-block is assigned to a tile; loaded chunks can then be accessed by all pixels associated with a tile at the same time. Additionally, threads which have finished rendering continue to load splats into shared memory, and only exit when *all* threads within a thread-block have finished.

A "render scale" parameter was created to allow reducing the render output resolution for a performance increase. It should be noted, however, that the reduction in rendered pixels is not proportional to the reduction in rendered splats (due to the requirement of in-order alpha blending). A decrease in resolution often equates to more splats assigned to a single tile for rendering. As a result, the performance gained from reducing the resolution is generally lower than one may expect. This could possibly be fixed by using a dynamic tile size.

Memory requirements are often on the order of GBs due to the space needed to hold the data for each Gaussian's spherical harmonic coefficients. Since the rasterizer is *hardcoded* to accept the first 3 degrees of spherical harmonics (16 coefficients, 3 floats each), 192 bytes are needed to encode color for each splat! Reducing the maximum degree of spherical harmonics would drastically reduce memory requirements, at the cost of less-accurate specular illumination.

## References
**Kerbl, Bernhard., et al**. **[3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/3d_gaussian_splatting_low.pdf)**. SIGGRAPH. (2023).\
**Kerbl, Bernhard., et al**. **[Differential Gaussian Rasterization](https://github.com/graphdeco-inria/diff-gaussian-rasterization)**. GitHub. (2023).\
**Xu, Zhen and yuzy**. **[Fast Gaussian Rasterization](https://github.com/dendenxu/fast-gaussian-rasterization)**. GitHub. (2024).\
**Zwicker, Matthias., et al**. **[EWA Splatting](https://www.cs.umd.edu/~zwicker/publications/EWASplatting-TVCG02.pdf)**. IEEE Transactions on Visualization and Computer Graphics. (2002).

## Attribution
**[Vulkan Radix Sort](https://github.com/jaesung-cs/vulkan_radix_sort)** by **jaesung-cs** is modified and used under the [MIT](https://github.com/jaesung-cs/vulkan_radix_sort/blob/master/LICENSE) license.  
**[La Chancellerie d’Orléans at Hôtel de Rohan in Paris](https://www.youtube.com/watch?v=vv3cvB6aNk8)** by **sasronen** was used for training the header demo model.
