#include "HitableList.hpp"
#include "Image.hpp"
#include "Ray.hpp"
#include "RayTracingCamera.hpp"
#include "Sphere.hpp"
#include "TestMaterial.hpp"
#include "geommath.hpp"

#include <curand_kernel.h>
#include <iostream>
#include <limits>

using ray = My::Ray<float>;
using color = My::Vector3<float>;
using point3 = My::Point<float>;
using vec3 = My::Vector3<float>;
using hit_record = My::Hit<float>;
using hitable = My::Hitable<float>;
using hitable_ptr = hitable *;
using image = My::Image;

using hitable_list = My::SimpleHitableList<float>;

using camera = My::RayTracingCamera<float>;

using sphere = My::Sphere<float, material *>;

// Device Management
#define checkCudaErrors(val) check_cuda((val), #val, __FILE__, __LINE__)
void check_cuda(cudaError_t result, char const *const func,
                const char *const file, int const line) {
    if (result) {
        std::cerr << "CUDA error = " << static_cast<unsigned int>(result)
                  << " (" << cudaGetErrorString(result) << ") "
                  << " at " << file << ":" << line << " '" << func << "' \n";
        cudaDeviceReset();
        exit(99);
    }
}

// Render
__device__ color ray_color(const ray &r, hitable_list **d_world,
                           curandState *local_rand_state) {
    ray cur_ray = r;
    color cur_attenuation{1.0f, 1.0f, 1.0f};
    for (int i = 0; i < 50; i++) {
        hit_record rec;
        if ((*d_world)->Intersect(cur_ray, rec, 0.001f, FLT_MAX)) {
            ray scattered;
            color attenuation;

            const material *pMat =
                *reinterpret_cast<material *const *>(rec.getMaterial());
            if (pMat && pMat->scatter(cur_ray, rec, attenuation, scattered,
                                      local_rand_state)) {
                cur_attenuation = cur_attenuation * attenuation;
                cur_ray = scattered;
            } else {
                return color({0.0f, 0.0f, 0.0f});
            }
        } else {
            vec3 unit_direction = r.getDirection();
            float t = 0.5f * (unit_direction[1] + 1.0f);
            vec3 c = (1.0f - t) * color({1.0, 1.0, 1.0}) +
                     t * color({0.5, 0.7, 1.0});
            return cur_attenuation * c;
        }
    }

    return color({0.0f, 0.0f, 0.0f});
}

__global__ void render_init(int max_x, int max_y, curandState *rand_state) {
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    int j = threadIdx.y + blockIdx.y * blockDim.y;
    if ((i >= max_x) || (j >= max_y)) return;
    int pixel_index = j * max_x + i;
    // Each thread gets same seed, a different sequence number, no offset
    curand_init(2022 + pixel_index, 0, 0, &rand_state[pixel_index]);
}

__global__ void render(vec3 *fb, int max_x, int max_y, int number_of_samples,
                       camera **cam, hitable_list **d_world,
                       curandState *rand_state) {
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    int j = threadIdx.y + blockIdx.y * blockDim.y;
    if ((i > max_x) || (j > max_y)) return;
    int pixel_index = j * max_x + i;
    curandState local_rand_state = rand_state[pixel_index];
    vec3 col({0, 0, 0});
    for (int s = 0; s < number_of_samples; s++) {
        float u = float(i + curand_uniform(&local_rand_state)) / float(max_x);
        float v = float(j + curand_uniform(&local_rand_state)) / float(max_y);
        ray r = (*cam)->get_ray(u, v, &local_rand_state);
        col += ray_color(r, d_world, &local_rand_state);
    }
    rand_state[pixel_index] = local_rand_state;
    fb[pixel_index] = pow(col / float(number_of_samples), 1.0f / 2.2f);
}

// World
__global__ void create_scene(hitable_list **d_world, camera **d_camera,
                             point3 lookfrom, point3 lookat, vec3 vup,
                             float vfov, float aspect_ratio, float aperture,
                             float focus_dist) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        hitable_ptr *pList = new hitable_ptr[2];
        *d_world = new hitable_list(pList, 2);
        pList[0] = new sphere(0.5f, point3({0, 0, -1}),
                              new lambertian(vec3({0.7, 0.3, 0.3})));
        pList[1] = new sphere(100.0f, point3({0, -100.5, -1}),
                              new lambertian(vec3({0.8, 0.8, 0.0})));

        *d_camera = new camera(lookfrom, lookat, vup, 20.0f, aspect_ratio,
                               aperture, focus_dist);
    }
}

__global__ void free_scene(hitable_list **d_world, camera **d_camera) {
    for (int i = 0; i < (*d_world)->size(); i++) {
        material *pmat = ((sphere *)((**d_world)[i]))->GetMaterial();
        if (pmat) delete pmat;
    }

    // delete *d_world;
    delete *d_camera;
}

int main() {
    // Render Settings
    const float aspect_ratio = 16.0 / 9.0;
    const int image_width = 1920;
    const int image_height = static_cast<int>(image_width / aspect_ratio);
    const int samples_per_pixel = 500;
    const int num_pixels = image_width * image_height;

    int tile_width = 8;
    int tile_height = 8;

    // Canvas
    image img;
    img.Width = image_width;
    img.Height = image_height;
    img.bitcount = 96;
    img.bitdepth = 32;
    img.pixel_format = My::PIXEL_FORMAT::RGB32;
    img.pitch = (img.bitcount >> 3) * img.Width;
    img.compressed = false;
    img.compress_format = My::COMPRESSED_FORMAT::NONE;
    img.data_size = img.Width * img.Height * (img.bitcount >> 3);

    checkCudaErrors(cudaMallocManaged((void **)&img.data, img.data_size));

    // Camera
    point3 lookfrom({0, 1, 5});
    point3 lookat({0, 0, -1});
    vec3 vup({0, 1, 0});
    auto dist_to_focus = 5.0;
    auto aperture = 0.01;

    camera **d_camera;
    checkCudaErrors(cudaMalloc((void **)&d_camera, sizeof(camera *)));

    // World
    hitable_list **d_world;
    checkCudaErrors(cudaMalloc((void **)&d_world, sizeof(hitable_list *)));

    create_scene<<<1, 1>>>(d_world, d_camera, lookfrom, lookat, vup, 75.0f,
                           aspect_ratio, aperture, dist_to_focus);

    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    // Pre-rendering
    curandState *d_rand_state;
    checkCudaErrors(
        cudaMalloc((void **)&d_rand_state, num_pixels * sizeof(curandState)));

    // Rendering
    dim3 blocks(image_width / tile_width + 1, image_height / tile_height + 1);
    dim3 threads(tile_width, tile_height);

    render_init<<<blocks, threads>>>(image_width, image_height, d_rand_state);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    render<<<blocks, threads>>>(reinterpret_cast<vec3 *>(img.data), image_width,
                                image_height, samples_per_pixel, d_camera,
                                d_world, d_rand_state);

    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    img.SaveTGA("raytracing_cuda.tga");

    // clean up
    checkCudaErrors(cudaDeviceSynchronize());
    free_scene<<<1, 1>>>(d_world, d_camera);
    checkCudaErrors(cudaGetLastError());

    checkCudaErrors(cudaFree(d_rand_state));
    checkCudaErrors(cudaFree(d_camera));
    checkCudaErrors(cudaFree(d_world));
    checkCudaErrors(cudaFree(img.data));
    img.data = nullptr;  // to avoid double free

    return 0;
}