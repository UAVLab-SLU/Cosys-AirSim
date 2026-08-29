// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "SimModeWorldMultiRotor.h"
#include "UObject/ConstructorHelpers.h"
#include "Logging/MessageLog.h"
#include "Engine/World.h"
#include "EngineUtils.h"
#include "GameFramework/PlayerController.h"
#include "Components/PrimitiveComponent.h"
#include "UObject/UObjectGlobals.h"
#include "WorldPartition/WorldPartitionSubsystem.h"

#include "AirBlueprintLib.h"
#include "vehicles/multirotor/api/MultirotorApiBase.hpp"
#include "MultirotorPawnSimApi.h"
#include "physics/PhysicsBody.hpp"
#include "common/ClockFactory.hpp"
#include <memory>
#include "vehicles/multirotor/api/MultirotorRpcLibServer.hpp"
#include "common/SteppableClock.hpp"

void ASimModeWorldMultiRotor::BeginPlay()
{
    Super::BeginPlay();

    // Set up the physics world without starting its asynchronous updater. On a
    // cold load, streamed terrain collision may not exist yet. Starting AirSim
    // physics here would apply gravity before the pawn can collide with it.
    initializeForPlay(false);

    UAirBlueprintLib::LogMessage(
        TEXT("AirSim physics waiting for terrain collision"),
        TEXT(""),
        LogDebugLevel::Informational);
}

void ASimModeWorldMultiRotor::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
    // Stop the physics thread before we dismantle it, if startup reached the
    // point where the thread was created.
    if (physics_updater_started_)
        stopAsyncUpdator();

    Super::EndPlay(EndPlayReason);
}

void ASimModeWorldMultiRotor::Tick(float DeltaSeconds)
{
    Super::Tick(DeltaSeconds);

    if (physics_updater_started_)
        return;

    startup_wait_log_elapsed_ += DeltaSeconds;

    if (!isWorldReadyForPhysics()) {
        ready_stable_elapsed_ = 0.0f;

        if (startup_wait_log_elapsed_ >= 5.0f) {
            startup_wait_log_elapsed_ = 0.0f;
            UAirBlueprintLib::LogMessage(
                TEXT("AirSim physics still waiting for terrain collision"),
                TEXT(""),
                LogDebugLevel::Informational);
        }
        return;
    }

    // Cesium may briefly report a usable collision surface while replacing
    // coarse tiles with the requested LOD. Require the complete readiness state
    // to remain stable long enough for Chaos collision changes to settle.
    constexpr float RequiredReadySeconds = 0.5f;
    ready_stable_elapsed_ += DeltaSeconds;
    if (ready_stable_elapsed_ < RequiredReadySeconds)
        return;

    // PhysicsWorld already reset every vehicle during initializeForPlay(). Do
    // not reset again here: AirSim requires an update between reset calls.
    startAsyncUpdator();
    physics_updater_started_ = true;

    UAirBlueprintLib::LogMessage(
        TEXT("AirSim terrain collision ready; multirotor physics started"),
        TEXT(""),
        LogDebugLevel::Success);
}

bool ASimModeWorldMultiRotor::isWorldReadyForPhysics() const
{
    UWorld* world = GetWorld();
    if (world == nullptr || world->IsVisibilityRequestPending())
        return false;

    UWorldPartitionSubsystem* world_partition = world->GetSubsystem<UWorldPartitionSubsystem>();
    if (world_partition != nullptr && !world_partition->IsAllStreamingCompleted())
        return false;

    if (!areCesiumTilesetsReady())
        return false;

    const auto& vehicle_sim_apis = getApiProvider()->getVehicleSimApis();
    for (auto* vehicle_sim_api : vehicle_sim_apis) {
        auto* multirotor_sim_api = static_cast<MultirotorPawnSimApi*>(vehicle_sim_api);
        if (multirotor_sim_api != nullptr && !hasBlockingSurfaceBelow(multirotor_sim_api->getPawn()))
            return false;
    }

    return true;
}

bool ASimModeWorldMultiRotor::areCesiumTilesetsReady() const
{
    // Keep Cesium optional. If its runtime module is present, discover the
    // tileset class and call its reflected GetLoadProgress function without a
    // compile-time dependency from AirSim to CesiumRuntime.
    UClass* tileset_class = FindObject<UClass>(
        nullptr,
        TEXT("/Script/CesiumRuntime.Cesium3DTileset"));
    if (tileset_class == nullptr)
        return true;

    UFunction* get_load_progress = tileset_class->FindFunctionByName(TEXT("GetLoadProgress"));
    if (get_load_progress == nullptr)
        return false;

    struct FGetLoadProgressParams
    {
        float ReturnValue = 0.0f;
    };

    for (TActorIterator<AActor> actor_it(GetWorld(), tileset_class); actor_it; ++actor_it) {
        AActor* tileset = *actor_it;
        if (!IsValid(tileset) || tileset->IsHidden())
            continue;

        FGetLoadProgressParams params;
        tileset->ProcessEvent(get_load_progress, &params);
        if (params.ReturnValue < 100.0f)
            return false;
    }

    return true;
}

bool ASimModeWorldMultiRotor::hasBlockingSurfaceBelow(APawn* pawn) const
{
    if (pawn == nullptr)
        return false;

    UPrimitiveComponent* root = Cast<UPrimitiveComponent>(pawn->GetRootComponent());
    if (root == nullptr || !root->IsQueryCollisionEnabled())
        return false;

    constexpr float StartupProbeDepth = 1000000.0f; // 10 km in default UE units
    constexpr float StartupProbeOffset = 100.0f;
    const FVector start = root->GetComponentLocation() + FVector(0.0f, 0.0f, StartupProbeOffset);
    const FVector end = start - FVector(0.0f, 0.0f, StartupProbeDepth);

    FCollisionQueryParams query_params(SCENE_QUERY_STAT(AirSimStartupTerrainProbe), false, pawn);
    query_params.AddIgnoredActor(pawn);

    FHitResult hit;
    return pawn->GetWorld()->LineTraceSingleByChannel(
        hit,
        start,
        end,
        root->GetCollisionObjectType(),
        query_params);
}

void ASimModeWorldMultiRotor::setupClockSpeed()
{
    typedef msr::airlib::ClockFactory ClockFactory;

    float clock_speed = getSettings().clock_speed;

    //setup clock in ClockFactory
    std::string clock_type = getSettings().clock_type;

    if (clock_type == "ScalableClock") {
        //scalable clock returns interval same as wall clock but multiplied by a scale factor
        ClockFactory::get(std::make_shared<msr::airlib::ScalableClock>(clock_speed == 1 ? 1 : 1 / clock_speed));
    }
    else if (clock_type == "SteppableClock") {
        //steppable clock returns interval that is a constant number irrespective of wall clock
        //we can either multiply this fixed interval by scale factor to speed up/down the clock
        //but that would cause vehicles like quadrotors to become unstable
        //so alternative we use here is instead to scale control loop frequency. The downside is that
        //depending on compute power available, we will max out control loop frequency and therefore can no longer
        //get increase in clock speed

        //Approach 1: scale clock period, no longer used now due to quadrotor instability
        //ClockFactory::get(std::make_shared<msr::airlib::SteppableClock>(
        //static_cast<msr::airlib::TTimeDelta>(getPhysicsLoopPeriod() * 1E-9 * clock_speed)));

        //Approach 2: scale control loop frequency if clock is speeded up
        if (clock_speed >= 1) {
            ClockFactory::get(std::make_shared<msr::airlib::SteppableClock>(
                static_cast<msr::airlib::TTimeDelta>(getPhysicsLoopPeriod() * 1E-9))); //no clock_speed multiplier

            setPhysicsLoopPeriod(getPhysicsLoopPeriod() / static_cast<long long>(clock_speed));
        }
        else {
            //for slowing down, this don't generate instability
            ClockFactory::get(std::make_shared<msr::airlib::SteppableClock>(
                static_cast<msr::airlib::TTimeDelta>(getPhysicsLoopPeriod() * 1E-9 * clock_speed)));
        }
    }
    else
        throw std::invalid_argument(common_utils::Utils::stringf(
            "clock_type %s is not recognized", clock_type.c_str()));
}

//-------------------------------- overrides -----------------------------------------------//

std::unique_ptr<msr::airlib::ApiServerBase> ASimModeWorldMultiRotor::createApiServer() const
{
#ifdef AIRLIB_NO_RPC
    return ASimModeBase::createApiServer();
#else
    return std::unique_ptr<msr::airlib::ApiServerBase>(new msr::airlib::MultirotorRpcLibServer(
        getApiProvider(), getSettings().api_server_address, getSettings().api_port));
#endif
}

void ASimModeWorldMultiRotor::getExistingVehiclePawns(TArray<AActor*>& pawns) const
{
    UAirBlueprintLib::FindAllActor<TVehiclePawn>(this, pawns);
}

bool ASimModeWorldMultiRotor::isVehicleTypeSupported(const std::string& vehicle_type) const
{
    return ((vehicle_type == AirSimSettings::kVehicleTypeSimpleFlight) ||
            (vehicle_type == AirSimSettings::kVehicleTypePX4) ||
            (vehicle_type == AirSimSettings::kVehicleTypeArduCopterSolo) ||
            (vehicle_type == AirSimSettings::kVehicleTypeArduCopter));
}

std::string ASimModeWorldMultiRotor::getVehiclePawnPathName(const AirSimSettings::VehicleSetting& vehicle_setting) const
{
    //decide which derived BP to use
    std::string pawn_path = vehicle_setting.pawn_path;
    if (pawn_path == "")
        pawn_path = "DefaultQuadrotor";

    return pawn_path;
}

PawnEvents* ASimModeWorldMultiRotor::getVehiclePawnEvents(APawn* pawn) const
{
    return static_cast<TVehiclePawn*>(pawn)->getPawnEvents();
}
const common_utils::UniqueValueMap<std::string, APIPCamera*> ASimModeWorldMultiRotor::getVehiclePawnCameras(
    APawn* pawn) const
{
    return (static_cast<const TVehiclePawn*>(pawn))->getCameras();
}
void ASimModeWorldMultiRotor::initializeVehiclePawn(APawn* pawn)
{
    static_cast<TVehiclePawn*>(pawn)->initializeForBeginPlay();
}
std::unique_ptr<PawnSimApi> ASimModeWorldMultiRotor::createVehicleSimApi(
    const PawnSimApi::Params& pawn_sim_api_params) const
{
    auto vehicle_sim_api = std::unique_ptr<PawnSimApi>(new MultirotorPawnSimApi(pawn_sim_api_params));
    vehicle_sim_api->initialize();
    //For multirotors the vehicle_sim_api are in PhysicsWOrld container and then get reseted when world gets reseted
    //vehicle_sim_api->reset();
    return vehicle_sim_api;
}
msr::airlib::VehicleApiBase* ASimModeWorldMultiRotor::getVehicleApi(const PawnSimApi::Params& pawn_sim_api_params,
                                                                    const PawnSimApi* sim_api) const
{
    const auto multirotor_sim_api = static_cast<const MultirotorPawnSimApi*>(sim_api);
    return multirotor_sim_api->getVehicleApi();
}
